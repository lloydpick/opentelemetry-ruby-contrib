# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'mysql2'

require_relative '../../../../lib/opentelemetry/instrumentation/mysql2'
require_relative '../../../../lib/opentelemetry/instrumentation/mysql2/patches/client'

# This test suite requires a running mysql container and dedicated test container
# To run tests:
# 1. Build the opentelemetry/opentelemetry-ruby-contrib image
# - docker-compose build
# 2. Bundle install
# - docker-compose run ex-instrumentation-mysql2-test bundle install
# 3. Run test suite
# - docker-compose run ex-instrumentation-mysql2-test bundle exec rake test
describe OpenTelemetry::Instrumentation::Mysql2::Instrumentation do
  let(:instrumentation) { OpenTelemetry::Instrumentation::Mysql2::Instrumentation.instance }
  let(:exporter) { EXPORTER }
  let(:span) { exporter.finished_spans.first }
  let(:config) { {} }

  before do
    exporter.reset
  end

  after do
    # Force re-install of instrumentation
    instrumentation.instance_variable_set(:@installed, false)
  end

  describe 'tracing' do
    let(:client) do
      Mysql2::Client.new(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password
      )
    end

    let(:host) { ENV.fetch('TEST_MYSQL_HOST', '127.0.0.1') }
    let(:port) { ENV.fetch('TEST_MYSQL_PORT', '3306') }
    let(:database) { ENV.fetch('TEST_MYSQL_DB', 'mysql') }
    let(:username) { ENV.fetch('TEST_MYSQL_USER', 'root') }
    let(:password) { ENV.fetch('TEST_MYSQL_PASSWORD', 'root') }

    before do
      instrumentation.install(config)
    end

    it 'before request' do
      _(exporter.finished_spans.size).must_equal 0
    end

    it 'accepts peer service name from config' do
      instrumentation.instance_variable_set(:@installed, false)
      instrumentation.install(peer_service: 'readonly:mysql')
      client.query('SELECT 1')

      _(span.attributes['peer.service']).must_equal 'readonly:mysql'
    end

    describe '.attributes' do
      let(:attributes) { { 'db.statement' => 'foobar' } }

      it 'returns an empty hash by default' do
        _(OpenTelemetry::Instrumentation::Mysql2.attributes).must_equal({})
      end

      it 'returns the current attributes hash' do
        OpenTelemetry::Instrumentation::Mysql2.with_attributes(attributes) do
          _(OpenTelemetry::Instrumentation::Mysql2.attributes).must_equal(attributes)
        end
      end

      it 'sets span attributes according to with_attributes hash' do
        OpenTelemetry::Instrumentation::Mysql2.with_attributes(attributes) do
          client.query('SELECT 1')
        end

        _(span.attributes['db.statement']).must_equal 'foobar'
      end
    end

    it 'after requests' do
      client.query('SELECT 1')

      _(span.name).must_equal 'select'
      _(span.attributes['db.system']).must_equal 'mysql'
      _(span.attributes['db.name']).must_equal 'mysql'
      _(span.attributes['db.statement']).must_equal 'SELECT 1'
      _(span.attributes['net.peer.name']).must_equal host.to_s
      _(span.attributes['net.peer.port']).must_equal port.to_s
    end

    it 'after error' do
      expect do
        client.query('SELECT INVALID')
      end.must_raise Mysql2::Error

      _(span.name).must_equal 'select'
      _(span.attributes['db.system']).must_equal 'mysql'
      _(span.attributes['db.name']).must_equal 'mysql'
      _(span.attributes['db.statement']).must_equal 'SELECT INVALID'
      _(span.attributes['net.peer.name']).must_equal host.to_s
      _(span.attributes['net.peer.port']).must_equal port.to_s

      _(span.status.code).must_equal(
        OpenTelemetry::Trace::Status::ERROR
      )
      _(span.events.first.name).must_equal 'exception'
      _(span.events.first.attributes['exception.type']).must_equal 'Mysql2::Error'
      assert(!span.events.first.attributes['exception.message'].nil?)
      assert(!span.events.first.attributes['exception.stacktrace'].nil?)
    end

    it 'extracts statement type that begins the query' do
      base_sql = 'SELECT 1'
      explain = 'EXPLAIN'
      explain_sql = "#{explain} #{base_sql}"
      client.query(explain_sql)

      _(span.name).must_equal 'explain'
      _(span.attributes['db.system']).must_equal 'mysql'
      _(span.attributes['db.name']).must_equal 'mysql'
      _(span.attributes['db.statement']).must_equal explain_sql
      _(span.attributes['net.peer.name']).must_equal host.to_s
      _(span.attributes['net.peer.port']).must_equal port.to_s
    end

    it 'uses component.name and instance.name as span.name fallbacks with invalid sql' do
      expect do
        client.query('DESELECT 1')
      end.must_raise Mysql2::Error

      _(span.name).must_equal 'mysql'
      _(span.attributes['db.system']).must_equal 'mysql'
      _(span.attributes['db.name']).must_equal 'mysql'
      _(span.attributes['db.statement']).must_equal 'DESELECT 1'
      _(span.attributes['net.peer.name']).must_equal host.to_s
      _(span.attributes['net.peer.port']).must_equal port.to_s

      _(span.status.code).must_equal(
        OpenTelemetry::Trace::Status::ERROR
      )
      _(span.events.first.name).must_equal 'exception'
      _(span.events.first.attributes['exception.type']).must_equal 'Mysql2::Error'
      assert(!span.events.first.attributes['exception.message'].nil?)
      assert(!span.events.first.attributes['exception.stacktrace'].nil?)
    end

    describe 'when db_statement set as obfuscate' do
      let(:config) { { db_statement: :obfuscate } }

      it 'obfuscates SQL parameters in db.statement' do
        sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
        obfuscated_sql = 'SELECT * from users where users.id = ? and users.email = ?'
        expect do
          client.query(sql)
        end.must_raise Mysql2::Error

        _(span.attributes['db.system']).must_equal 'mysql'
        _(span.attributes['db.name']).must_equal 'mysql'
        _(span.name).must_equal 'select'
        _(span.attributes['db.statement']).must_equal obfuscated_sql
        _(span.attributes['net.peer.name']).must_equal host.to_s
        _(span.attributes['net.peer.port']).must_equal port.to_s
      end

      it 'encodes invalid byte sequences for db.statement' do
        # \255 is off-limits https://en.wikipedia.org/wiki/UTF-8#Codepage_layout
        sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com\255'"
        obfuscated_sql = 'SELECT * from users where users.id = ? and users.email = ?'

        expect do
          client.query(sql)
        end.must_raise Mysql2::Error

        _(span.name).must_equal 'mysql'
        _(span.attributes['db.statement']).must_equal obfuscated_sql
      end
    end

    describe 'when db_statement set as omit' do
      let(:config) { { db_statement: :omit } }

      it 'omits db.statement attribute' do
        sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
        expect do
          client.query(sql)
        end.must_raise Mysql2::Error

        _(span.attributes['db.system']).must_equal 'mysql'
        _(span.attributes['db.name']).must_equal 'mysql'
        _(span.name).must_equal 'select'
        _(span.attributes).wont_include('db.statement')
        _(span.attributes['net.peer.name']).must_equal host.to_s
        _(span.attributes['net.peer.port']).must_equal port.to_s
      end
    end

    describe 'when db_statement is configured via environment variable' do
      describe 'when db_statement set as omit' do
        it 'omits db.statement attribute' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'db_statement=omit;') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install
            sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
            expect do
              client.query(sql)
            end.must_raise Mysql2::Error

            _(span.attributes['db.system']).must_equal 'mysql'
            _(span.attributes['db.name']).must_equal 'mysql'
            _(span.name).must_equal 'select'
            _(span.attributes).wont_include('db.statement')
            _(span.attributes['net.peer.name']).must_equal host.to_s
            _(span.attributes['net.peer.port']).must_equal port.to_s
          end
        end
      end

      describe 'when db_statement set as obfuscate' do
        it 'obfuscates SQL parameters in db.statement' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'db_statement=obfuscate;') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install

            sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
            obfuscated_sql = 'SELECT * from users where users.id = ? and users.email = ?'
            expect do
              client.query(sql)
            end.must_raise Mysql2::Error

            _(span.attributes['db.system']).must_equal 'mysql'
            _(span.attributes['db.name']).must_equal 'mysql'
            _(span.name).must_equal 'select'
            _(span.attributes['db.statement']).must_equal obfuscated_sql
            _(span.attributes['net.peer.name']).must_equal host.to_s
            _(span.attributes['net.peer.port']).must_equal port.to_s
          end
        end
      end

      describe 'when db_statement is set differently than local config' do
        let(:config) { { db_statement: :omit } }

        it 'overrides local config and obfuscates SQL parameters in db.statement' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'db_statement=obfuscate') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install

            sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
            obfuscated_sql = 'SELECT * from users where users.id = ? and users.email = ?'
            expect do
              client.query(sql)
            end.must_raise Mysql2::Error

            _(span.attributes['db.system']).must_equal 'mysql'
            _(span.attributes['db.name']).must_equal 'mysql'
            _(span.name).must_equal 'select'
            _(span.attributes['db.statement']).must_equal obfuscated_sql
            _(span.attributes['net.peer.name']).must_equal host.to_s
            _(span.attributes['net.peer.port']).must_equal port.to_s
          end
        end
      end

      describe 'when span_name is set as statement_type' do
        it 'sets span name to statement type' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=statement_type') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install

            sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
            expect do
              client.query(sql)
            end.must_raise Mysql2::Error

            _(span.name).must_equal 'select'
          end
        end

        it 'sets span name to mysql when statement type is not recognized' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=statement_type') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install

            sql = 'DESELECT 1'
            expect do
              client.query(sql)
            end.must_raise Mysql2::Error

            _(span.name).must_equal 'mysql'
          end
        end
      end

      describe 'when span_name is set as db_name' do
        it 'sets span name to db name' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=db_name') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install

            sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
            expect do
              client.query(sql)
            end.must_raise Mysql2::Error

            _(span.name).must_equal 'mysql' # TODO: change the db name so we can distinguish it from the default
          end
        end

        describe 'when db name is nil' do
          let(:database) { nil }

          it 'sets span name to mysql' do
            OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=db_name') do
              instrumentation.instance_variable_set(:@installed, false)
              instrumentation.install

              sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
              expect do
                client.query(sql)
              end.must_raise Mysql2::Error

              _(span.name).must_equal 'mysql'
            end
          end
        end
      end

      describe 'when span_name is set as db_operation_and_name' do
        it 'sets span name to db operation and name' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=db_operation_and_name') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install

            sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
            OpenTelemetry::Instrumentation::Mysql2.with_attributes('db.operation' => 'foo') do
              expect do
                client.query(sql)
              end.must_raise Mysql2::Error
            end

            _(span.name).must_equal 'foo mysql'
          end
        end

        it 'sets span name to db name when db.operation is not set' do
          OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=db_operation_and_name') do
            instrumentation.instance_variable_set(:@installed, false)
            instrumentation.install

            sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
            expect do
              client.query(sql)
            end.must_raise Mysql2::Error

            _(span.name).must_equal 'mysql'
          end
        end

        describe 'when db name is nil' do
          let(:database) { nil }

          it 'sets span name to db operation' do
            OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=db_operation_and_name') do
              instrumentation.instance_variable_set(:@installed, false)
              instrumentation.install

              sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
              OpenTelemetry::Instrumentation::Mysql2.with_attributes('db.operation' => 'foo') do
                expect do
                  client.query(sql)
                end.must_raise Mysql2::Error
              end

              _(span.name).must_equal 'foo'
            end
          end

          it 'sets span name to mysql when db.operation is not set' do
            OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_INSTRUMENTATION_MYSQL2_CONFIG_OPTS' => 'span_name=db_name') do
              instrumentation.instance_variable_set(:@installed, false)
              instrumentation.install

              sql = "SELECT * from users where users.id = 1 and users.email = 'test@test.com'"
              expect do
                client.query(sql)
              end.must_raise Mysql2::Error

              _(span.name).must_equal 'mysql'
            end
          end
        end
      end
    end
  end unless ENV['OMIT_SERVICES']
end
