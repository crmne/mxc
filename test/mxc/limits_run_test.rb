# frozen_string_literal: true

require 'test_helper'

module MXC
  class LimitsRunTest < Minitest::Test
    BUSY = 'i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done'
    FOREVER = 'while :; do :; done'

    def setup
      super
      skip 'these commands need a POSIX shell; WindowsRunTest covers Windows' if Preflight.windows?
      skip_unless_supported
    end

    def test_reports_cpu_time_only_with_limits_or_a_priority
      result = MXC.run(BUSY, priority: :low)

      assert_predicate result, :success?
      assert_operator result.cpu_time, :>, 0
      assert_nil result.limit_exceeded
      assert_nil MXC.run(BUSY).cpu_time
    end

    def test_cpu_time_includes_the_processes_the_command_waited_for
      alone = MXC.run(BUSY, limits: { cpu_time: 60 }).cpu_time
      both = MXC.run("sh -c '#{BUSY}' & sh -c '#{BUSY}' & wait", limits: { cpu_time: 60 }).cpu_time

      assert_operator both, :>, alone * 1.5
    end

    def test_a_cpu_time_limit_stops_the_command
      result = MXC.run(FOREVER, limits: { cpu_time: 1 }, timeout: 30)

      refute_predicate result, :success?
      refute_predicate result, :timed_out?
      assert_equal :cpu_time, result.limit_exceeded
      assert_operator result.cpu_time, :>=, 0.9
    end

    def test_a_cpu_time_limit_holds_when_the_command_ignores_sigxcpu
      result = MXC.run("trap '' XCPU; #{FOREVER}", limits: { cpu_time: 1 }, timeout: 30)

      refute_predicate result, :timed_out?
      assert_equal :cpu_time, result.limit_exceeded
    end

    def test_a_memory_limit_fails_large_allocations
      skip 'macOS has no memory limit' unless MXC.supports?(:memory_limit)
      allocate = "python3 -c 'bytearray(512 * 1024 * 1024); print(\"allocated\")'"
      skip 'python3 cannot allocate 512 MB here' unless MXC.run(allocate).success?

      result = MXC.run(allocate, limits: { memory: 256 * 1024 * 1024 })

      refute_predicate result, :success?
      assert_match 'MemoryError', result.stderr
      assert_nil result.limit_exceeded
    end

    def test_priority_lowers_the_nice_value
      command = Preflight.linux? ? 'cut -d " " -f 19 /proc/self/stat' : %(perl -e 'print getpriority(0, 0)')

      assert_equal '10', MXC.run(command, priority: :low).stdout.strip
      assert_equal '19', MXC.run(command, priority: :lowest).stdout.strip
    end

    def test_spawned_and_streamed_commands_report_usage
      process = MXC.spawn(BUSY, limits: { cpu_time: 60 })
      chunks = []
      streamed = MXC.run("#{BUSY}; echo done", limits: { cpu_time: 60 }) { |chunk| chunks << chunk.content }

      assert_operator process.wait.cpu_time, :>, 0
      assert_operator streamed.cpu_time, :>, 0
      assert_equal "done\n", chunks.join
    end

    def test_a_process_limit_is_refused_before_starting
      skip 'Windows counts processes' if MXC.supports?(:process_limit)

      assert_raises(UnsupportedError) { MXC.run('true', limits: { processes: 2 }) }
    end
  end
end
