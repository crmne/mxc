# frozen_string_literal: true

require 'test_helper'

module MXC
  class HostTest < Minitest::Test
    def setup
      super
      @availability = MXC.instance_variable_get(:@availability).dup
      MXC.instance_variable_get(:@availability).clear
    end

    def teardown
      MXC.instance_variable_set(:@availability, @availability)
      super
    end

    def test_probes_each_backend_once
      calls = []
      Availability.stub(:probe, lambda { |backend|
        calls << backend
        Availability.new(backend:, supported: true)
      }) do
        assert_predicate MXC, :supported?
        assert_predicate MXC, :supported?
        assert MXC.supported?(backend: :bubblewrap)
        MXC.availability(refresh: true)
      end

      assert_equal %i[auto bubblewrap auto], calls
    end

    def test_the_probe_runs_true_in_a_sandbox
      commands = []

      Native.stub(:run, lambda { |command, _|
        commands << command
        outcome
      }) do
        assert_predicate Availability.probe(:auto), :supported?
      end
      assert_equal 1, commands.size
      assert_match 'exit 0', commands.first
    end

    def test_a_failed_sandbox_start_is_unsupported_with_a_remediation
      Native.stub(:run, lambda { |*|
        outcome(exit_code: 1, stderr: "bwrap: Can't mount proc on /newroot/proc: Operation not permitted\n")
      }) do
        availability = Availability.probe(:auto)

        refute_predicate availability, :supported?
        assert_match "Can't mount proc", availability.reason
        assert_match 'running-in-docker', availability.remediation
      end
    end

    def test_native_errors_make_the_host_unsupported
      Native.stub(:run, ->(*) { raise UnsupportedError.new('no bwrap', remediation: 'install bubblewrap') }) do
        availability = Availability.probe(:auto)

        refute_predicate availability, :supported?
        assert_equal 'install bubblewrap', availability.remediation
      end
    end

    def test_nothing_is_supported_on_an_unsupported_host
      MXC.stub(:supported?, false) do
        refute MXC.supports?(:network)
        refute MXC.supports?(:network_policy)
        refute MXC.supports?(:proxy_enforcement)
      end
    end

    def test_capabilities_map_to_backends_and_network_tools
      backends = [{ name: :bubblewrap, tier: nil, capabilities: [:proxy_enforcement], warnings: [] }]
      MXC.stub(:supported?, true) do
        Native.stub(:backends, backends) do
          Preflight.stub(:problem, nil) do
            assert MXC.supports?(:network)
            assert MXC.supports?(:network_policy)
            assert MXC.supports?(:proxy_enforcement)
            refute MXC.supports?(:capture_denials)
          end
          Preflight.stub(:problem, UnsupportedError.new('no slirp4netns')) do
            refute MXC.supports?(:network)
            refute MXC.supports?(:network_policy)
          end
        end
      end
    end

    def test_backends_are_value_objects
      Native.stub(:backends, [{ name: :bubblewrap, tier: nil, capabilities: [], warnings: ['no slirp4netns'] }]) do
        backend = MXC.backends.first

        assert_equal :bubblewrap, backend.name
        assert_equal ['no slirp4netns'], backend.warnings
      end
    end

    def test_backend_names_follow_ruby_naming
      Native.stub(:backends, [{ name: :processcontainer, tier: 'base-container', capabilities: [], warnings: [] }]) do
        assert_equal [:process_container], MXC.backends.map(&:name)
      end
    end

    def test_real_backends_report_symbols
      MXC.backends.each do |backend|
        assert_kind_of Symbol, backend.name
        assert(backend.capabilities.all?(Symbol))
      end
    end

    def test_the_real_probe_matches_a_real_run
      ran = begin
        MXC.run('exit 0').success?
      rescue Error
        false
      end

      assert_equal ran, MXC.supported?
    end
  end

  class PreflightTest < Minitest::Test
    def with_tools(names)
      Dir.mktmpdir do |dir|
        names.each do |name|
          path = File.join(dir, name)
          File.write(path, "#!/bin/sh\n")
          File.chmod(0o755, path)
        end
        tun = File.join(dir, 'tun')
        File.write(tun, '')
        yield dir, tun
      end
    end

    def test_skips_sandboxes_without_network
      assert_nil Preflight.problem(network: false, path: '', tun: '/nonexistent')
    end

    def test_names_missing_tools_with_an_install_hint
      skip 'only Linux needs network tools' unless Preflight.linux?

      with_tools(%w[slirp4netns nsenter unshare]) do |dir, tun|
        error = Preflight.problem(network: { allow: ['pypi.org'] }, path: dir, tun:)

        assert_instance_of UnsupportedError, error
        assert_match 'iptables', error.message
        refute_match 'slirp4netns', error.message
        assert_match 'apt-get install slirp4netns iptables', error.remediation
        assert_equal :backend_unavailable, error.code
      end
    end

    def test_requires_a_usable_tun_device_for_open_network_too
      skip 'only Linux needs network tools' unless Preflight.linux?

      with_tools(Preflight::NETWORK_TOOLS) do |dir, _|
        error = Preflight.problem(network: true, path: dir, tun: '/nonexistent/tun')

        assert_match '/nonexistent/tun', error.message
        assert_match(%r{--device /dev/net/tun|modprobe tun}, error.remediation)
      end
    end

    def test_passes_when_everything_is_present
      with_tools(Preflight::NETWORK_TOOLS) do |dir, tun|
        assert_nil Preflight.problem(network: true, path: dir, tun:)
      end
    end
  end

  class StartupFailureTest < Minitest::Test
    def failure(stderr, exit_code: 1, stdout: '')
      StartupFailure.detect(outcome(exit_code:, stdout:, stderr:))
    end

    def test_namespace_denial_is_unsupported_with_a_docker_hint
      error = failure("bwrap: No permissions to create a new namespace, likely because ...\n")

      assert_instance_of UnsupportedError, error
      assert_equal :backend_unavailable, error.code
      assert_match 'seccomp', error.remediation
    end

    def test_masked_proc_points_at_the_docker_guide
      error = failure("bwrap: Can't mount proc on /newroot/proc: Operation not permitted\n")

      assert_instance_of UnsupportedError, error
      assert_match 'running-in-docker', error.remediation
    end

    def test_a_missing_working_directory_is_a_usage_error
      error = failure("bwrap: Can't chdir to /nowhere: No such file or directory\n")

      assert_instance_of Error, error
      assert_match 'readable', error.remediation
    end

    def test_ordinary_failures_stay_results
      assert_nil failure("bwrap: x\n", exit_code: 2)
      assert_nil failure("bwrap: x\n", stdout: 'output')
      assert_nil failure("bwrap: x\nmore\n")
      assert_nil failure("python: error\n")
      assert_nil StartupFailure.detect(outcome(timed_out: true, exit_code: nil))
    end
  end
end
