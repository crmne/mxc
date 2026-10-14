# frozen_string_literal: true

require 'test_helper'
require 'socket'

module MXC
  class WindowsRunTest < Minitest::Test
    FINDSTR = 'C:\\Windows\\System32\\findstr.exe'
    FOREVER = 'for /l %i in (0,0,1) do @rem'

    def setup
      super
      skip 'cmd.exe commands run only on Windows' unless Preflight.windows?
      skip_unless_supported
      @dir = Dir.mktmpdir('mxc-test')
      @readable = windows_path(File.join(@dir, 'readable'))
      @writable = windows_path(File.join(@dir, 'writable'))
      [@readable, @writable].each { |path| Dir.mkdir(path) }
      File.binwrite(File.join(@readable, 'input.txt'), "hello\r\na b\r\na\r\n")
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir
      super
    end

    def test_runs_a_command_through_cmd
      result = MXC.run('echo hi&(echo oops)1>&2&exit 3')

      assert_equal "hi\r\n", result.stdout
      assert_equal "oops\r\n", result.stderr
      assert_equal 3, result.exit_code
      assert_equal :process_container, result.backend
    end

    def test_times_out
      result = MXC.run(FOREVER, timeout: 0.5)

      assert_predicate result, :timed_out?
      assert_nil result.exit_code
    end

    def test_reports_cpu_time_with_limits_or_a_priority
      result = MXC.run('for /l %i in (1,1,20000) do @rem', priority: :low)

      assert_predicate result, :success?
      assert_kind_of Float, result.cpu_time
      assert_nil result.limit_exceeded
      assert_nil MXC.run('echo hi').cpu_time
    end

    def test_a_cpu_time_limit_stops_the_command
      result = MXC.run(FOREVER, limits: { cpu_time: 1 }, timeout: 30)

      refute_predicate result, :success?
      refute_predicate result, :timed_out?
      assert_equal :cpu_time, result.limit_exceeded
    end

    def test_a_process_limit_refuses_more_processes
      refused = MXC.run('cmd /c echo inner', limits: { processes: 1 })
      allowed = MXC.run('cmd /c echo inner', limits: { processes: 2 })

      refute_predicate refused, :success?
      assert_equal :processes, refused.limit_exceeded
      assert_equal "inner\r\n", allowed.stdout
      assert_nil allowed.limit_exceeded
    end

    def test_reads_only_readable_paths_and_writes_only_writable_ones
      script = "type #{@readable}\\input.txt > #{@writable}\\output.txt&" \
               "(echo x> #{@readable}\\hack) 2>NUL || echo read-only"
      result = MXC.run(script, readable: @readable, writable: @writable)

      assert_equal "read-only\r\n", result.stdout
      assert_equal "hello\r\na b\r\na\r\n", File.binread(File.join(@writable, 'output.txt'))
      refute_path_exists File.join(@readable, 'hack')
    end

    def test_cannot_read_paths_it_was_not_given
      result = MXC.run("type #{@readable}\\input.txt")

      refute_predicate result, :success?
      assert_match 'denied', result.stderr
    end

    def test_cannot_read_the_users_profile
      refute_predicate MXC.run("dir #{ENV.fetch('USERPROFILE')}"), :success?
    end

    def test_denied_paths_stay_hidden_inside_readable_ones
      skip 'MXC does not enforce denied paths in an AppContainer' unless MXC.supports?(:filesystem_denied_paths)

      result = MXC.run("type #{@readable}\\input.txt", readable: windows_path(@dir), denied: @readable)

      refute_predicate result, :success?
    end

    def test_denied_paths_raise_where_they_would_not_be_enforced
      skip 'this host enforces denied paths' if MXC.supports?(:filesystem_denied_paths)

      error = assert_raises(UnsupportedError) { MXC.run('exit 0', readable: windows_path(@dir), denied: @readable) }

      assert_match 'readable and writable', error.remediation
      refute_predicate MXC.sandbox.with_denied(@readable), :supported?
    end

    def test_sets_the_environment_and_directory
      result = MXC.run('echo %GREETING%&cd', env: { 'GREETING' => 'hi' }, readable: @readable, directory: @readable)

      assert_equal "hi\r\n#{@readable}\r\n", result.stdout
    end

    def test_starts_in_the_system_root_by_default
      assert_equal "#{ENV.fetch('SystemRoot')}\r\n", MXC.run('cd').stdout
    end

    def test_each_command_gets_its_own_temporary_folder
      result = MXC.run('echo x> "%TEMP%\\probe.txt"&type "%TEMP%\\probe.txt"&echo %TEMP%')

      assert_equal 'x', result.stdout.lines.first.strip
      refute_equal ENV.fetch('TEMP'), result.stdout.lines.last.strip
    end

    def test_an_open_network_cannot_reach_localhost
      server = TCPServer.new('127.0.0.1', 0)
      curl = "#{ENV.fetch('SystemRoot')}\\System32\\curl.exe"
      result = MXC.run(%("#{curl}" -sS -m 5 http://127.0.0.1:#{server.addr[1]}/), network: true, timeout: 30)

      assert_includes [7, 28], result.exit_code, result.stderr
    ensure
      server&.close
    end

    def test_does_not_inherit_the_parents_environment
      ENV['MXC_TEST_SECRET'] = 'leaked'

      assert_equal "%MXC_TEST_SECRET%\r\n", MXC.run('echo %MXC_TEST_SECRET%').stdout
    ensure
      ENV.delete('MXC_TEST_SECRET')
    end

    def test_streams_output_and_returns_the_result
      chunks = []
      result = MXC.run('echo one&(echo two)1>&2') { |chunk| chunks << chunk }

      assert_equal "one\r\n", chunks.select(&:stdout?).map(&:content).join
      assert_equal "two\r\n", chunks.select(&:stderr?).map(&:content).join
      assert_predicate result, :success?
    end

    def test_streaming_respects_the_timeout
      result = MXC.run("echo started&#{FOREVER}", timeout: 0.5) { nil }

      assert_predicate result, :timed_out?
      assert_equal "started\r\n", result.stdout
    end

    def test_spawned_programs_take_arguments_and_input
      process = MXC.spawn(FINDSTR, '/c:p g', timeout: 5)
      process.write("p g\r\nother\r\n")
      process.close_write

      assert_equal "p g\r\n", process.each.map(&:content).join
      assert_predicate process.wait, :success?
    end

    def test_spawned_processes_take_input
      process = MXC.spawn(%("#{FINDSTR}" .*), timeout: 5)
      process.write("ping\r\n")
      process.close_write

      assert_equal "ping\r\n", process.each.map(&:content).join
      assert_predicate process.wait, :success?
    end

    def test_spawned_processes_can_be_killed_while_reading
      process = MXC.spawn("echo started&#{FOREVER}")
      Thread.new do
        sleep 0.5
        process.kill
      end

      assert_equal "started\r\n", process.each.map(&:content).join
      refute_predicate process.wait, :success?
    end

    def test_waiting_drains_output_nobody_read
      result = MXC.spawn('for /l %i in (1,1,5000) do @echo %i', timeout: 60).wait

      assert_equal 5000, result.stdout.lines.size
    end

    def test_unquoted_program_paths_go_through_the_unreadable_drive_root
      skip 'this host lets the sandbox read the drive root' if MXC.run('dir C:\\').success?

      refute_predicate MXC.run("#{FINDSTR} /?"), :success?
      assert_predicate MXC.run(%("#{FINDSTR}" /?)), :success?
    end

    def test_arguments_reach_the_program_unchanged
      result = MXC.run(FINDSTR, '/c:a b', "#{@readable}\\input.txt", readable: @readable)

      assert_equal "a b\r\n", result.stdout
    end

    def test_arguments_are_not_interpreted_by_cmd
      result = MXC.run(FINDSTR, '/c:%PATH%&echo injected', "#{@readable}\\input.txt", readable: @readable)

      assert_empty result.stdout
      refute_match 'injected', result.stderr
    end

    def test_allow_lists_raise_before_anything_starts
      error = assert_raises(UnsupportedError) { MXC.run('exit 0', network: { allow: ['pypi.org'] }) }

      assert_match 'network: true', error.remediation
      refute MXC.supports?(:network_policy)
    end

    private

    def windows_path(path)
      File.expand_path(path).tr('/', '\\')
    end
  end
end
