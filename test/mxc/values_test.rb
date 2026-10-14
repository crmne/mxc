# frozen_string_literal: true

require 'test_helper'

module MXC
  class ValuesTest < Minitest::Test
    def result(**overrides)
      Result.new(**outcome(**overrides), backend: :bubblewrap)
    end

    def test_results_expose_the_outcome
      result = result(stdout: 'out', stderr: 'err', warnings: ['w'], blocked: ['example.com:443'])

      assert_predicate result, :success?
      refute_predicate result, :timed_out?
      assert_equal 'out', result.stdout
      assert_equal 'err', result.stderr
      assert_equal 0, result.exit_code
      assert_equal ['w'], result.warnings
      assert_equal ['example.com:443'], result.blocked
      assert_equal :bubblewrap, result.backend
    end

    def test_results_are_unsuccessful_on_failure_or_timeout
      refute_predicate result(exit_code: 3), :success?
      refute_predicate result(exit_code: nil, timed_out: true), :success?
      assert_predicate result(exit_code: nil, timed_out: true), :timed_out?
    end

    def test_result_output_uses_the_default_external_encoding
      result = result(stdout: "caf\xC3\xA9".b)

      assert_equal Encoding.default_external, result.stdout.encoding
      assert_predicate result.stdout, :frozen?
    end

    def test_results_serialize_and_inspect_on_one_line
      result = result(exit_code: 2)

      assert_equal 2, result.to_h[:exit_code]
      refute result.to_h[:timed_out]
      assert_equal '#<MXC::Result exit_code=2 timed_out=false backend=:bubblewrap>', result.inspect
    end

    def test_chunks_name_their_stream
      chunk = Chunk.new(stream: :stderr, content: 'oops')

      assert_predicate chunk, :stderr?
      refute_predicate chunk, :stdout?
      assert_equal 'oops', chunk.content
      assert_equal '#<MXC::Chunk stream=:stderr content="oops">', chunk.inspect
    end

    def test_backends_answer_capability_queries
      backend = Backend.new(name: :bubblewrap, capabilities: [:proxy_enforcement], warnings: [])

      assert backend.supports?(:proxy_enforcement)
      refute backend.supports?(:capture_denials)
      assert_nil backend.tier
      assert_equal '#<MXC::Backend name=:bubblewrap tier=nil capabilities=[:proxy_enforcement]>', backend.inspect
    end

    def test_availability_reports_reason_and_remediation
      availability = Availability.new(backend: :auto, supported: false, reason: 'no bwrap', remediation: 'install it')

      refute_predicate availability, :supported?
      assert_equal 'no bwrap', availability.reason
      assert_equal 'install it', availability.remediation
      refute_includes availability.inspect, "\n"
    end

    def test_errors_take_the_message_first_and_details_as_keywords
      error = Error.new('boom', code: :backend_error, remediation: 'fix it', operation: 'run', native_code: '5')

      assert_equal 'boom', error.message
      assert_equal :backend_error, error.code
      assert_equal 'fix it', error.remediation
      assert_equal 'run', error.operation
      assert_equal '5', error.native_code
      assert_kind_of Error, UnsupportedError.new('x')
    end

    def test_native_unavailability_errors_are_unsupported_errors
      assert_instance_of UnsupportedError, Native.error('x', code: :backend_unavailable)
      assert_instance_of UnsupportedError, Native.error('x', code: :unsupported_containment)
      assert_instance_of Error, Native.error('x', code: :backend_error, remediation: nil)
    end

    def test_a_missing_bubblewrap_is_unsupported_with_install_instructions
      error = Native.error('Bubblewrap (bwrap) is not installed or not on PATH.', code: :backend_error)

      assert_instance_of UnsupportedError, error
      assert_equal :backend_unavailable, error.code
      assert_match 'apt-get install bubblewrap', error.remediation
    end

    def test_configuration_validates_its_settings
      MXC.configure do |config|
        config.backend = 'bubblewrap'
        config.timeout = 60
      end

      assert_equal :bubblewrap, MXC.config.backend
      assert_equal 60, MXC.config.timeout
      assert_raises(ArgumentError) { MXC.config.backend = :docker }
      assert_raises(ArgumentError) { MXC.config.timeout = 0 }
    end
  end
end
