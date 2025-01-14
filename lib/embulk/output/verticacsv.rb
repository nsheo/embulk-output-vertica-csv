require 'vertica'
require 'tempfile'
require 'securerandom'
require_relative 'verticacsv/value_converter_factory'
require_relative 'verticacsv/output_thread'

module Embulk
  module Output
    class VerticaCSV < OutputPlugin
      Plugin.register_output('verticacsv', self)

      class Error < StandardError; end
      class NotSupportedType < Error; end

      def self.thread_pool
        @thread_pool ||= @thread_pool_proc.call
      end

      def self.transaction_report(jv, task, task_reports)
        quoted_schema     = ::Vertica.quote_identifier(task['schema'])
        quoted_table = ::Vertica.quote_identifier(task['table'])

        num_input_rows = task_reports.map {|report| report['num_input_rows'].to_i }.inject(:+)
        num_total_rows = task_reports.map {|report| report['num_output_rows'].to_i }.inject(:+)
        result = query(jv, %[SELECT COUNT(*) FROM #{quoted_schema}.#{quoted_table}])
        num_output_rows = result.map {|row| row.values }.flatten.first.to_i
        num_rejected_rows = num_input_rows - num_output_rows
        transaction_report = {
          'num_input_rows' => num_input_rows,
          'num_total_rows' => num_total_rows,
          'num_output_rows' => num_output_rows,
          'num_rejected_rows' => num_rejected_rows,
        }
      end

      def self.transaction(config, schema, task_count, &control)
        task = {
          'host'             => config.param('host',             :string,  :default => 'localhost'),
          'port'             => config.param('port',             :integer, :default => 5433),
          'user'             => config.param('user',             :string,  :default => nil),
          'username'         => config.param('username',         :string,  :default => nil), # alias to :user for backward compatibility
          'password'         => config.param('password',         :string,  :default => ''),
          'database'         => config.param('database',         :string,  :default => 'vdb'),
          'schema'           => config.param('schema',           :string,  :default => 'public'),
          'table'            => config.param('table',            :string),
		      'load_time_col'    => config.param('load_time_col',    :string,  :default => nil), #column name for loading time
		      'delimiter_str'    => config.param('delimiter_str',    :string,  :default => '|'), #Delimiter for vertica copy
          'mode'             => config.param('mode',             :string,  :default => 'DIRECT_COPY'),
          'copy_mode'        => config.param('copy_mode',        :string,  :default => 'DIRECT'),
          'abort_on_error'   => config.param('abort_on_error',   :bool,    :default => false),
          'default_timezone' => config.param('default_timezone', :string, :default => 'UTC'),
          'column_options'   => config.param('column_options',   :hash,    :default => {}),
          'csv_payload'      => config.param('csv_payload',     :bool,    :default => false),
          'resource_pool'    => config.param('resource_pool',    :string,  :default => nil),
          'reject_on_materialized_type_error' => config.param('reject_on_materialized_type_error', :bool, :default => false),
          'pool'             => config.param('pool',             :integer, :default => task_count),
          'write_timeout'    => config.param('write_timeout',    :integer, :default => nil), # like 11 * 60 sec
          'dequeue_timeout'  => config.param('dequeue_timeout',  :integer, :default => nil), # like 13 * 60 sec
          'finish_timeout'   => config.param('finish_timeout',   :integer, :default => nil), # like 3 * 60 sec
        }

        @thread_pool_proc = Proc.new do
          OutputThreadPool.new(task, schema, task['pool'])
        end

        task['user'] ||= task['username']
        unless task['user']
          raise ConfigError.new 'required field "user" is not set'
        end

        task['mode'] = task['mode'].upcase
        unless %w[DIRECT_COPY].include?(task['mode'])
          raise ConfigError.new "`mode` must be one of DIRECT_COPY"
        end

        task['copy_mode'] = task['copy_mode'].upcase
        unless %w[AUTO DIRECT TRICKLE].include?(task['copy_mode'])
          raise ConfigError.new "`copy_mode` must be one of AUTO, DIRECT, TRICKLE"
        end

        now = Time.now
        unique_name = SecureRandom.uuid
        quoted_schema     = ::Vertica.quote_identifier(task['schema'])
        quoted_table      = ::Vertica.quote_identifier(task['table'])
        
        connect(task) do |jv|
          Embulk.logger.info { "embulk-output-verticacsv: VerticaConnection start" }
        end

        begin
          # insert data into the temp table
          thread_pool.start
          yield(task)
          task_reports = thread_pool.commit
          Embulk.logger.info { "embulk-output-verticacsv: task_reports: #{task_reports.to_json}" }

          connect(task) do |jv|
            transaction_report = self.transaction_report(jv, task, task_reports)
            Embulk.logger.info { "embulk-output-verticacsv: transaction_report: #{transaction_report.to_json}" }

            if task['abort_on_error'] # double-meaning, also used for COPY statement
              if transaction_report['num_input_rows'] != transaction_report['num_output_rows']
                raise Error, "ABORT: `num_input_rows (#{transaction_report['num_input_rows']})` and " \
                  "`num_output_rows (#{transaction_report['num_output_rows']})` does not match"
              end
            end
          end
        ensure
          connect(task) do |jv|
            Embulk.logger.trace { "embulk-output-verticacsv: select result\n#{query(jv, %[SELECT * FROM #{quoted_schema}.#{quoted_table} LIMIT 10]).map {|row| row.to_h }.join("\n") rescue nil}" }
          end
        end
        # this is for -o next_config option, add some paramters for next time execution if wants
        next_config_diff = {}
        return next_config_diff
      end

      # instance is created on each thread
      def initialize(task, schema, index)
        super
      end

      # called for each page in each thread
      def close
      end

      # called for each page in each thread
      def add(page)
        self.class.thread_pool.enqueue(page)
      end

      def finish
      end

      def abort
      end

      # called after processing all pages in each thread
      # we do commit on #transaction for all pools, not at here
      def commit
        {}
      end

      private

      def self.connect(task)
        jv = ::Vertica.connect({
          host: task['host'],
          port: task['port'],
          user: task['user'],
          password: task['password'],
          database: task['database'],
        })

        if resource_pool = task['resource_pool']
          query(jv, "SET SESSION RESOURCE_POOL = #{::Vertica.quote(resource_pool)}")
        end

        if block_given?
          begin
            yield jv
          ensure
            jv.close
          end
        end
        jv
      end

      # @param [Schema] schema embulk defined column types
      # @param [Hash]   column_options user defined column types
      # @return [String] sql schema used to CREATE TABLE
      def self.sql_schema_from_embulk_schema(schema, column_options)
        sql_schema = schema.names.zip(schema.types).map do |column_name, type|
          if column_options[column_name] and column_options[column_name]['type']
            sql_type = column_options[column_name]['type']
          else
            sql_type = sql_type_from_embulk_type(type)
          end
          [column_name, sql_type]
        end
        sql_schema.map {|name, type| "#{::Vertica.quote_identifier(name)} #{type}" }.join(',')
      end

      def self.sql_type_from_embulk_type(type)
        case type
        when :boolean then 'BOOLEAN'
        when :long then 'INT' # BIGINT is a synonym for INT in vertica
        when :double then 'FLOAT' # DOUBLE PRECISION is a synonym for FLOAT in vertica
        when :string then 'VARCHAR' # LONG VARCHAR is not recommended. Default is VARCHAR(80)
        when :timestamp then 'TIMESTAMP'
        else raise NotSupportedType, "embulk-output-vertica cannot take column type #{type}"
        end
      end

      def self.query(conn, sql)
        Embulk.logger.info "embulk-output-verticacsv: #{sql}"
        conn.query(sql)
      end

      def query(conn, sql)
        self.class.query(conn, sql)
      end
    end
  end
end
