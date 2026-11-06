# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'

module MXC
  class ProcessEnvironmentTest < Minitest::Test
    CANARY = 'mxc-canary-not-a-real-secret'
    SCAN = 'for file in /proc/[0-9]*/environ /proc/[0-9]*/cmdline; do cat "$file" 2>/dev/null; echo; done'
    LIB = File.expand_path('../../lib', __dir__)

    def setup
      super
      skip 'reading another process through /proc is Linux only' unless Preflight.linux?
      ENV['MXC_TEST_CANARY'] = CANARY
    end

    def teardown
      ENV.delete('MXC_TEST_CANARY')
      super
    end

    def test_bubblewrap_cannot_read_the_host_environment
      assert_nothing_visible(MXC.run(SCAN, backend: bubblewrap))
    end

    def test_bubblewrap_with_limits_cannot_read_the_host_environment
      assert_nothing_visible(MXC.run(SCAN, backend: bubblewrap, limits: { cpu_time: 30 }))
    end

    def test_bubblewrap_with_network_cannot_read_the_host_environment
      skip_unless_network

      assert_nothing_visible(MXC.run(SCAN, backend: bubblewrap, network: true))
      assert_nothing_visible(MXC.run(SCAN, backend: bubblewrap, network: { allow: ['example.com'] }))
    end

    def test_bubblewrap_cannot_read_a_variable_the_process_started_with
      backend = bubblewrap
      script = "require 'mxc'; print MXC.run(#{SCAN.dump}, backend: :#{backend}).stdout"
      stdout, status = Open3.capture2({ 'MXC_TEST_CANARY' => CANARY }, RbConfig.ruby, '-I', LIB, '-e', script)

      assert_predicate status, :success?
      refute_empty stdout
      refute_includes stdout, CANARY
    end

    def test_bubblewrap_still_sets_the_configured_environment
      result = MXC.run('echo "$CONFIGURED"; echo "[$MXC_TEST_CANARY]"', backend: bubblewrap,
                                                                        env: { 'CONFIGURED' => 'for the command' })

      assert_equal "for the command\n[]\n", result.stdout
    end

    def test_landlock_cannot_read_the_host_environment
      assert_nothing_visible(MXC.run(SCAN, backend: landlock))
    end

    def test_landlock_cannot_read_a_process_of_the_same_user
      neighbour = ::Process.spawn({ 'MXC_TEST_NEIGHBOUR' => CANARY }, 'sleep', '30')
      result = MXC.run("cat /proc/#{neighbour}/environ", backend: landlock)

      refute_predicate result, :success?
      refute_includes result.stdout, CANARY
    ensure
      stop(neighbour)
    end

    def test_a_sandbox_cannot_read_the_environment_of_another_sandbox
      [bubblewrap_if_supported, landlock_if_supported].compact.each do |backend|
        other = MXC.spawn('echo started; sleep 30', backend:, env: { 'MXC_TEST_OTHER' => CANARY })
        other.to_enum(:each).first

        assert_nothing_visible(MXC.run(SCAN, backend:))
        other.kill
        other.wait
      end
    end

    private

    def assert_nothing_visible(result)
      assert_predicate result, :success?, result.stderr
      refute_empty result.stdout
      refute_includes result.stdout, CANARY
    end

    def bubblewrap = bubblewrap_if_supported || skip("no Bubblewrap: #{MXC.availability(backend: :bubblewrap).reason}")
    def landlock = landlock_if_supported || skip("no Landlock: #{MXC.availability(backend: :landlock).reason}")
    def bubblewrap_if_supported = (:bubblewrap if MXC.supported?(backend: :bubblewrap))
    def landlock_if_supported = (:landlock if MXC.supported?(backend: :landlock))

    def stop(pid)
      ::Process.kill('TERM', pid)
      ::Process.wait(pid)
    end
  end
end
