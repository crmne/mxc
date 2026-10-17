# frozen_string_literal: true

require 'test_helper'
require 'rbconfig'

module MXC
  class LandlockRunTest < Minitest::Test
    def setup
      super
      skip 'Landlock is Linux only' unless Preflight.linux?
      skip "no Landlock on this host: #{MXC.availability(backend: :landlock).reason}" unless
        MXC.supported?(backend: :landlock)
      MXC.config.backend = :landlock
      @dir = Dir.mktmpdir('mxc-landlock')
      @readable = File.join(@dir, 'readable')
      @writable = File.join(@dir, 'writable')
      [@readable, @writable].each { |path| Dir.mkdir(path) }
      File.write(File.join(@readable, 'input.txt'), 'hello')
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir
      super
    end

    def test_reads_and_writes_only_what_the_policy_grants
      result = MXC.run('cat input.txt > ../writable/out.txt; echo more >> input.txt',
                       readable: @readable, writable: @writable, directory: @readable)

      assert_equal :landlock, result.backend
      assert_equal 'hello', File.read(File.join(@writable, 'out.txt'))
      assert_match 'input.txt', result.stderr
      refute_predicate MXC.run("ls #{Dir.home}"), :success?
    end

    def test_metadata_outside_the_policy_stays_unchanged
      key = File.join(@dir, 'key')
      File.write(key, 'secret')
      File.chmod(0o600, key)
      File.write(File.join(@writable, 'out'), '')
      result = MXC.run("chmod 644 #{key}; touch -d 2001-01-01 #{key}; chmod +x out; touch out new && echo touched",
                       writable: @writable, directory: @writable)

      assert_equal 0o600, File.stat(key).mode & 0o777
      assert_match 'Operation not permitted', result.stderr
      assert_equal "touched\n", result.stdout
      assert_path_exists File.join(@writable, 'new')
      refute File.executable?(File.join(@writable, 'out'))
    end

    def test_denied_paths_inside_a_grant_are_refused
      error = assert_raises(UnsupportedError) { MXC.run('true', writable: @writable, denied: "#{@writable}/secret") }

      assert_match 'Landlock', error.message
    end

    def test_limits_and_usage_work
      result = MXC.run('while :; do :; done', limits: { cpu_time: 1 }, priority: :low, timeout: 30)

      assert_equal :cpu_time, result.limit_exceeded
      assert_operator result.cpu_time, :>=, 0.9
    end

    def test_spawned_commands_run_on_landlock
      process = MXC.spawn('cat', readable: @readable)
      process.write('hi')
      result = process.wait

      assert_equal 'hi', result.stdout
      assert_equal :landlock, result.backend
    end

    def test_auto_falls_back_where_namespaces_are_blocked
      skip 'Bubblewrap cannot block namespaces here' unless MXC.supported?(backend: :bubblewrap)

      probe = 'r = MXC.run("true"); print r.backend, " ", MXC.supports?(:network)'
      output = IO.popen(['bwrap', '--dev-bind', '/', '/', '--unshare-user', '--disable-userns', '--',
                         RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-rmxc', '-e', probe],
                        err: File::NULL, &:read)
      skip 'bwrap --disable-userns is not available' unless ::Process.last_status.success?

      assert_equal 'landlock false', output
    end
  end
end
