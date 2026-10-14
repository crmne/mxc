# frozen_string_literal: true

require 'test_helper'

module MXC
  class RunTest < Minitest::Test
    def setup
      super
      skip 'these commands need a POSIX shell; WindowsRunTest covers Windows' if Preflight.windows?
      skip_unless_supported
      @dir = Dir.mktmpdir('mxc-test')
      @readable = File.join(@dir, 'readable')
      @writable = File.join(@dir, 'writable')
      [@readable, @writable].each { |path| Dir.mkdir(path) }
      File.write(File.join(@readable, 'input.txt'), 'hello')
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir
      super
    end

    def test_runs_a_command
      result = MXC.run('echo hi; echo oops >&2; exit 3')

      assert_equal "hi\n", result.stdout
      assert_equal "oops\n", result.stderr
      assert_equal 3, result.exit_code
      refute_predicate result, :success?
    end

    def test_times_out
      result = MXC.run('sleep 5', timeout: 0.3)

      assert_predicate result, :timed_out?
      assert_nil result.exit_code
    end

    def test_reads_only_readable_paths_and_writes_only_writable_ones
      script = "cat #{@readable}/input.txt > #{@writable}/output.txt; " \
               "echo x > #{@readable}/hack 2>/dev/null || echo read-only"
      result = MXC.run(script, readable: @readable, writable: @writable)

      assert_equal "read-only\n", result.stdout
      assert_equal 'hello', File.read(File.join(@writable, 'output.txt'))
      refute_path_exists File.join(@readable, 'hack')
    end

    def test_cannot_see_paths_it_was_not_given
      result = MXC.run("ls #{@dir}")

      refute_predicate result, :success?
    end

    def test_denied_paths_stay_hidden_inside_readable_ones
      result = MXC.run("cat #{@readable}/input.txt", readable: @dir, denied: @readable)

      refute_predicate result, :success?
    end

    def test_sets_the_environment_and_directory
      result = MXC.run('echo $GREETING; pwd', env: { 'GREETING' => 'hi' }, readable: @readable, directory: @readable)

      assert_equal "hi\n#{@readable}\n", result.stdout
    end

    def test_a_directory_outside_the_sandbox_raises
      skip 'Seatbelt starts commands in directories they cannot read' unless Preflight.linux?

      error = assert_raises(Error) { MXC.run('pwd', directory: @readable) }

      assert_match 'readable', error.remediation
    end

    def test_a_directory_outside_the_sandbox_stays_unreadable
      skip 'Bubblewrap refuses to start in a directory it cannot see' if Preflight.linux?

      result = MXC.run('pwd; cat input.txt', directory: @readable)

      assert_equal "#{@readable}\n", result.stdout
      refute_predicate result, :success?
    end

    def test_streams_output_and_returns_the_result
      chunks = []
      result = MXC.run('echo one; echo two >&2') { |chunk| chunks << chunk }

      assert_equal "one\n", chunks.select(&:stdout?).map(&:content).join
      assert_equal "two\n", chunks.select(&:stderr?).map(&:content).join
      assert_equal "one\n", result.stdout
      assert_predicate result, :success?
    end

    def test_streaming_respects_the_timeout
      result = MXC.run('echo started; sleep 5', timeout: 0.5) { nil }

      assert_predicate result, :timed_out?
      assert_equal "started\n", result.stdout
    end

    def test_spawned_processes_take_input
      process = MXC.spawn('cat', timeout: 5)
      process.write("ping\n")
      process.close_write

      assert_equal ["ping\n"], process.each.map(&:content)
      assert_predicate process.wait, :success?
      assert_same process.wait, process.wait
    end

    def test_spawned_processes_can_be_killed_while_reading
      process = MXC.spawn('echo started; sleep 30')
      Thread.new do
        sleep 0.2
        process.kill
      end

      assert_equal ["started\n"], process.each.map(&:content)
      refute_predicate process.wait, :success?
    end

    def test_waiting_drains_output_nobody_read
      result = MXC.spawn('seq 1 20000', timeout: 10).wait

      assert_equal 20_000, result.stdout.lines.size
    end

    def test_arguments_are_not_interpreted_by_the_shell
      result = MXC.run('printf', '[%s]\n', '$HOME; echo injected', 'a b', 'c"d', '')

      assert_equal "[$HOME; echo injected]\n[a b]\n[c\"d]\n[]\n", result.stdout
    end

    def test_streams_a_program_and_its_arguments
      chunks = []
      result = MXC.sandbox.run('echo', 'a  b') { |chunk| chunks << chunk.content }

      assert_equal "a  b\n", chunks.join
      assert_predicate result, :success?
    end

    def test_spawns_a_program_and_its_arguments
      process = MXC.spawn('cat', '-u', timeout: 5)
      process.write("ping\n")

      assert_equal "ping\n", process.wait.stdout
    end

    def test_a_sandbox_without_network_cannot_resolve_names
      skip 'no systemd-resolved on this host' unless File.exist?('/run/systemd/resolve')

      refute_predicate MXC.run('getent hosts example.com'), :success?
    end
  end
end
