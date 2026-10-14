# frozen_string_literal: true

require 'test_helper'

module MXC
  class LimitsTest < Minitest::Test
    Duration = Struct.new(:to_f)
    Bytes = Struct.new(:to_i)

    def resources(sandbox)
      _, request = capture_request(sandbox)
      request[:resources]
    end

    def test_limits_and_priority_chain_and_read_back
      sandbox = MXC.sandbox.with_limits(cpu_time: 90, memory: 2 * (1024**3)).with_priority(:low)

      assert_equal({ cpu_time: 90, memory: 2 * (1024**3) }, sandbox.limits)
      assert_equal :low, sandbox.priority
      assert_predicate sandbox.limits, :frozen?
    end

    def test_limits_merge_and_nil_removes_them
      sandbox = MXC.sandbox.with_limits(cpu_time: 5).with_limits(memory: 1024)

      assert_equal({ cpu_time: 5, memory: 1024 }, sandbox.limits)
      assert_equal({ memory: 1024 }, sandbox.with_limits(cpu_time: nil).limits)
      assert_empty sandbox.with_limits(nil).limits
    end

    def test_priority_defaults_to_normal_and_nil_resets_it
      assert_equal :normal, MXC.sandbox.priority
      assert_equal :lowest, MXC.sandbox.with_priority('lowest').priority
      assert_equal :normal, MXC.sandbox.with_priority(:low).with_priority(nil).priority
    end

    def test_limits_accept_durations_and_byte_counts
      sandbox = MXC.sandbox.with_limits(cpu_time: Duration.new(120.0), memory: Bytes.new(2048 * 1024 * 1024))

      assert_equal({ cpu_time_ms: 120_000, memory_mb: 2048 }, resources(sandbox))
    end

    def test_invalid_limits_raise
      assert_raises(ArgumentError) { MXC.sandbox.with_limits(cpu: 1) }
      assert_raises(ArgumentError) { MXC.sandbox.with_limits(cpu_time: 0) }
      assert_raises(ArgumentError) { MXC.sandbox.with_limits(cpu_time: -1) }
      assert_raises(ArgumentError) { MXC.sandbox.with_limits(memory: Object.new) }
      assert_raises(ArgumentError) { MXC.sandbox.with_limits(processes: 1.5) }
      assert_raises(ArgumentError) { MXC.sandbox.with_limits({ cpu_time: 1 }) }
      assert_raises(ArgumentError) { MXC.sandbox.with_priority(:high) }
    end

    def test_class_macros_and_keywords_set_limits_and_priority
      parent = Class.new(Sandbox) do
        limits cpu_time: 60
        priority :low
      end
      child = Class.new(parent) { limits memory: 1024**3 }

      assert_equal({ cpu_time: 60, memory: 1024**3 }, child.new.limits)
      assert_equal :low, child.new.priority
      assert_equal({ cpu_time: 60 }, parent.new.limits)

      sandbox = Sandbox.new(limits: { processes: 4 }, priority: :lowest)

      assert_equal({ processes: 4 }, sandbox.limits)
      assert_equal :lowest, sandbox.priority
    end

    def test_requests_round_limits_up_and_name_the_priority
      sandbox = MXC.sandbox.with_limits(cpu_time: 1.0001, memory: (1024 * 1024) + 1, processes: 8)

      assert_equal({ cpu_time_ms: 1001, memory_mb: 2, max_processes: 8 }, resources(sandbox))
      assert_equal({ priority: 'low' }, resources(MXC.sandbox.with_priority(:low)))
      assert_equal({ priority: 'idle' }, resources(MXC.sandbox.with_priority(:lowest)))
    end

    def test_requests_without_limits_carry_no_resources
      assert_nil resources(MXC.sandbox)
      assert_nil resources(MXC.sandbox.with_priority(:normal))
    end

    def test_inspect_shows_limits_only_when_set
      refute_includes MXC.sandbox.inspect, 'limits'
      assert_includes MXC.sandbox.with_limits(cpu_time: 5).inspect, "limits=#{{ cpu_time: 5 }.inspect} priority=:normal"
    end

    def test_process_limits_are_unsupported_outside_windows
      Preflight.stub(:windows?, false) do
        Preflight.stub(:linux?, true) do
          error = assert_raises(UnsupportedError) { MXC.run('true', limits: { processes: 2 }) }

          assert_equal 'Process limits are not supported on Linux', error.message
          assert_includes error.remediation, '--pids-limit'
        end
      end
    end

    def test_memory_limits_are_unsupported_on_macos
      Preflight.stub(:windows?, false) do
        Preflight.stub(:linux?, false) do
          error = assert_raises(UnsupportedError) { MXC.run('true', limits: { memory: 1024**3 }) }

          assert_equal 'Memory limits are not supported on macOS', error.message
          refute_predicate MXC.sandbox.with_limits(memory: 1024**3).availability, :supported?
          assert_nil Preflight.resource_problem({ cpu_time_ms: 1000, priority: 'idle' })
        end
      end
    end

    def test_windows_supports_every_limit
      Preflight.stub(:windows?, true) do
        assert_nil Preflight.resource_problem({ cpu_time_ms: 1, memory_mb: 1, max_processes: 1, priority: 'low' })
      end
    end

    def test_capabilities_follow_the_platform
      MXC.stub(:supported?, true) do
        Preflight.stub(:windows?, false) do
          Preflight.stub(:linux?, false) do
            assert MXC.supports?(:cpu_time_limit)
            assert MXC.supports?(:priority)
            refute MXC.supports?(:memory_limit)
            refute MXC.supports?(:process_limit)
          end
          Preflight.stub(:linux?, true) do
            assert MXC.supports?(:memory_limit)
            refute MXC.supports?(:process_limit)
          end
        end

        Preflight.stub(:windows?, true) { assert MXC.supports?(:process_limit) }
      end

      MXC.stub(:supported?, false) { refute MXC.supports?(:cpu_time_limit) }
    end

    def test_results_report_cpu_time_and_the_limit
      result = Result.new(**outcome(exit_code: 137, cpu_time: 1.0042, limit_exceeded: :cpu_time),
                          backend: :bubblewrap)

      assert_in_delta 1.0042, result.cpu_time
      assert_equal :cpu_time, result.limit_exceeded
      assert_equal :cpu_time, result.to_h[:limit_exceeded]
      assert_equal '#<MXC::Result exit_code=137 timed_out=false cpu_time=1.004 limit_exceeded=:cpu_time ' \
                   'backend=:bubblewrap>', result.inspect
    end

    def test_results_without_usage_report_nil
      result = Result.new(**outcome, backend: :bubblewrap)

      assert_nil result.cpu_time
      assert_nil result.limit_exceeded
      assert_equal '#<MXC::Result exit_code=0 timed_out=false backend=:bubblewrap>', result.inspect
    end
  end
end
