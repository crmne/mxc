# frozen_string_literal: true

require 'test_helper'

module MXC
  class SandboxTest < Minitest::Test
    Seconds = Struct.new(:to_f)

    def test_setters_chain_and_readers_return_what_was_set
      sandbox = MXC.sandbox
                   .with_readable('app/skills', Pathname('lib'))
                   .with_writable(Pathname('/tmp/out'))
                   .with_denied('config/credentials')
                   .with_env('LANG' => 'C.UTF-8', PORT: 3000)
                   .with_directory(Pathname('app/skills'))
                   .with_timeout(30)
                   .with_backend(:bubblewrap)

      assert_equal %w[app/skills lib], sandbox.readable
      assert_equal ['/tmp/out'], sandbox.writable
      assert_equal ['config/credentials'], sandbox.denied
      assert_equal({ 'LANG' => 'C.UTF-8', 'PORT' => '3000' }, sandbox.env)
      assert_equal 'app/skills', sandbox.directory
      assert_equal 30, sandbox.timeout
      assert_equal :bubblewrap, sandbox.backend
      refute sandbox.network
    end

    def test_paths_and_env_accumulate_and_nil_resets_them
      sandbox = MXC.sandbox.with_readable('a').with_readable('b').with_env('A' => '1').with_env('B' => '2')

      assert_equal %w[a b], sandbox.readable
      assert_equal %w[A B], sandbox.env.keys
      assert_empty sandbox.with_readable(nil).readable
      assert_empty sandbox.with_env(nil).env
    end

    def test_nil_resets_scalar_settings_to_the_configuration
      MXC.config.timeout = 60
      sandbox = MXC.sandbox.with_timeout(5).with_backend(:seatbelt).with_directory('x').with_network(true)

      sandbox.with_timeout(nil).with_backend(nil).with_directory(nil).with_network(nil)

      assert_equal 60, sandbox.timeout
      assert_equal :auto, sandbox.backend
      assert_nil sandbox.directory
      refute sandbox.network
    end

    def test_network_takes_a_boolean_or_an_allow_list
      assert MXC.sandbox.with_network.network
      refute MXC.sandbox.with_network(false).network
      assert_equal({ allow: ['pypi.org', '*.pythonhosted.org'] },
                   MXC.sandbox.with_network(allow: ['pypi.org', '*.pythonhosted.org']).network)
      assert_raises(ArgumentError) { MXC.sandbox.with_network(false, allow: ['pypi.org']) }
      assert_raises(ArgumentError) { MXC.sandbox.with_network(:yes) }
    end

    def test_timeouts_accept_anything_with_to_f
      assert_equal Seconds.new(90.0), MXC.sandbox.with_timeout(Seconds.new(90.0)).timeout
      assert_raises(ArgumentError) { MXC.sandbox.with_timeout(0) }
      assert_raises(ArgumentError) { MXC.sandbox.with_timeout(-1) }
    end

    def test_backends_are_symbols_from_a_known_list
      assert_equal :seatbelt, MXC.sandbox.with_backend('seatbelt').backend
      assert_raises(ArgumentError) { MXC.sandbox.with_backend(:docker) }
    end

    def test_new_applies_keyword_options
      sandbox = Sandbox.new(readable: ['a', Pathname('b')], writable: 'c', network: { allow: ['pypi.org'] },
                            env: { 'A' => '1' }, directory: 'a', timeout: 2, backend: :bubblewrap)

      assert_equal %w[a b], sandbox.readable
      assert_equal ['c'], sandbox.writable
      assert_equal({ allow: ['pypi.org'] }, sandbox.network)
      assert_equal({ 'A' => '1' }, sandbox.env)
      assert_equal 2, sandbox.timeout
      assert Sandbox.new(network: true).network
    end

    def test_new_rejects_unknown_options
      error = assert_raises(ArgumentError) { Sandbox.new(readonly: 'a') }

      assert_match 'readonly', error.message
    end

    def test_readers_cannot_change_the_sandbox
      sandbox = MXC.sandbox.with_readable('a')

      assert_raises(FrozenError) { sandbox.readable << 'b' }
      assert_raises(FrozenError) { sandbox.env['A'] = '1' }
    end

    def test_dup_copies_settings
      original = MXC.sandbox.with_readable('a').with_env('A' => '1')
      copy = original.dup.with_readable('b').with_env('B' => '2')

      assert_equal ['a'], original.readable
      assert_equal({ 'A' => '1' }, original.env)
      assert_equal %w[a b], copy.readable
    end

    def test_inspect_is_one_line
      inspect = MXC.sandbox.with_readable('a').inspect

      assert_match(/\A#<MXC::Sandbox backend=:auto network=false readable=\["a"\]/, inspect)
      refute_includes inspect, "\n"
    end

    def test_requests_expand_paths_and_convert_settings
      sandbox = MXC.sandbox.with_readable('app').with_writable('tmp').with_denied('/secret')
                   .with_env('A' => '1').with_directory('app').with_timeout(1.5).with_backend(:bubblewrap)

      _, request = Preflight.stub(:windows?, false) { capture_request(sandbox) }

      assert_equal [File.expand_path('app')], request[:readonly]
      assert_equal [File.expand_path('tmp')], request[:readwrite]
      assert_includes request[:denied], File.expand_path('/secret')
      assert_equal({ 'A' => '1' }, request[:environment])
      assert_equal File.expand_path('app'), request[:working_directory]
      assert_equal 1500, request[:timeout_ms]
      assert_equal :bubblewrap, request[:backend]
      refute request[:network]
      assert_nil request[:allow]
    end

    def test_requests_carry_the_network_policy
      _, open = capture_request(MXC.sandbox.with_network(true))
      _, listed = capture_request(MXC.sandbox.with_network(allow: ['pypi.org']))

      assert open[:network]
      refute listed[:network]
      assert_equal ['pypi.org'], listed[:allow]
    end

    def test_requests_use_the_configured_timeout_and_backend
      MXC.configure do |config|
        config.timeout = 2
        config.backend = :bubblewrap
      end

      _, request = capture_request(MXC.sandbox)

      assert_equal 2000, request[:timeout_ms]
      assert_equal :bubblewrap, request[:backend]
    end

    def test_hides_the_host_resolver_unless_the_network_is_open
      skip 'no systemd-resolved on this host' unless File.exist?('/run/systemd/resolve')

      _, closed = capture_request(MXC.sandbox)
      _, listed = capture_request(MXC.sandbox.with_network(allow: ['pypi.org']))
      _, open = capture_request(MXC.sandbox.with_network(true))

      assert_includes closed[:denied], '/run/systemd/resolve'
      assert_includes listed[:denied], '/run/systemd/resolve'
      refute_includes open[:denied], '/run/systemd/resolve'
    end

    def test_one_string_runs_through_the_shell
      line, = Preflight.stub(:windows?, false) { capture_request(MXC.sandbox, 'echo $HOME && ls | wc -l') }

      assert_equal 'echo $HOME && ls | wc -l', line
    end

    def test_programs_and_arguments_are_escaped
      line, = Preflight.stub(:windows?, false) { capture_request(MXC.sandbox, 'printf', '%s', 'a b; rm -rf /', '') }

      assert_equal Shellwords.join(['printf', '%s', 'a b; rm -rf /', '']), line
    end

    def test_programs_and_arguments_accept_pathnames
      line, = Preflight.stub(:windows?, false) { capture_request(MXC.sandbox, Pathname('/usr/bin/env'), 'a b') }

      assert_equal '/usr/bin/env a\\ b', line
    end

    def test_arrays_raise
      [[%w[python3 build.py]], ['python3', %w[build.py]]].each do |command|
        error = assert_raises(ArgumentError) { capture_request(MXC.sandbox, *command) }

        assert_match 'separate Strings', error.message
      end
    end

    def test_arrays_raise_before_anything_starts
      MXC::Native.stub(:spawn, ->(*) { flunk 'spawned an Array command' }) do
        assert_raises(ArgumentError) { MXC.spawn(%w[python3 build.py]) }
        assert_raises(ArgumentError) { MXC.run(%w[python3 build.py]) { nil } }
      end
    end

    def test_a_missing_command_raises
      assert_raises(ArgumentError) { MXC.run }
      assert_raises(ArgumentError) { MXC.sandbox.spawn }
    end

    def test_arguments_that_are_not_strings_raise
      assert_raises(TypeError) { capture_request(MXC.sandbox, 'sleep', 5) }
      assert_raises(TypeError) { capture_request(MXC.sandbox, 'ls', { timeout: 5 }) }
    end

    def test_module_run_takes_the_command_and_policy_keywords
      captured = nil
      native = lambda { |line, request|
        captured = [line, request]
        outcome
      }
      Preflight.stub(:windows?, false) do
        MXC::Native.stub(:run, native) { MXC.run('python3', 'build.py', 'a b', timeout: 30) }
      end

      assert_equal 'python3 build.py a\\ b', captured[0]
      assert_equal 30_000, captured[1][:timeout_ms]
    end

    def test_run_returns_a_result
      result = MXC::Native.stub(:run, ->(*) { outcome(stdout: "hi\n", warnings: ['w']) }) { MXC.sandbox.run('echo hi') }

      assert_instance_of Result, result
      assert_equal "hi\n", result.stdout
      assert_equal ['w'], result.warnings
      assert_includes %i[bubblewrap seatbelt process_container], result.backend
    end

    def test_run_checks_network_tools_before_starting_anything
      Preflight.stub(:check!, ->(**) { raise UnsupportedError, 'missing slirp4netns' }) do
        MXC::Native.stub(:run, ->(*) { flunk 'ran despite a failed preflight' }) do
          assert_raises(UnsupportedError) { MXC.run('true', network: { allow: ['pypi.org'] }) }
        end
      end
    end

    def test_run_raises_when_bubblewrap_cannot_start
      MXC::Native.stub(:run, ->(*) { setup_failure("bwrap: Can't mount proc on /newroot/proc\n") }) do
        assert_raises(UnsupportedError) { MXC.run('true') }
      end
    end

    def test_an_unsupported_network_policy_makes_the_sandbox_unsupported
      problem = UnsupportedError.new('no slirp4netns', remediation: 'install it')
      Preflight.stub(:problem, problem) do
        availability = MXC.sandbox.with_network(true).availability

        refute_predicate availability, :supported?
        assert_equal 'install it', availability.remediation
      end
    end
  end

  class WindowsRequestTest < Minitest::Test
    def on_windows(sandbox, *command, env: ENV.to_h, &)
      Preflight.stub(:windows?, true) do
        ENV.stub(:to_h, env) do
          ENV.stub(:fetch, ->(name, *) { env[name] }) { capture_request(sandbox, *command) }
        end
      end
    end

    def test_strings_run_through_cmd
      line, = on_windows(MXC.sandbox, 'echo hi & exit 3')

      assert_equal 'cmd.exe /d /s /c "echo hi & exit 3"', line
    end

    def test_programs_and_arguments_are_quoted_for_command_line_to_argv
      line, = on_windows(MXC.sandbox, 'C:\\Program Files\\tool.exe', 'a b', 'say "hi"', 'dir\\', '', 'plain')

      assert_equal '"C:\\Program Files\\tool.exe" "a b" "say \\"hi\\"" dir\\ "" plain', line
    end

    def test_programs_and_arguments_refuse_batch_files
      error = assert_raises(ArgumentError) { on_windows(MXC.sandbox, 'build.CMD', 'x & y') }

      assert_match 'cmd.exe', error.message
    end

    def test_one_string_may_start_a_batch_file_through_cmd
      line, = on_windows(MXC.sandbox, 'build.cmd x')

      assert_equal 'cmd.exe /d /s /c "build.cmd x"', line
    end

    def test_arrays_raise
      assert_raises(ArgumentError) { on_windows(MXC.sandbox, %w[findstr.exe a]) }
    end

    def test_paths_use_backslashes
      _, request = on_windows(MXC.sandbox.with_readable('app').with_directory('app'))

      assert_equal [File.expand_path('app').tr('/', '\\')], request[:readonly]
      assert_equal File.expand_path('app').tr('/', '\\'), request[:working_directory]
    end

    def test_commands_start_in_the_system_root_by_default
      _, request = on_windows(MXC.sandbox, env: { 'SystemRoot' => 'C:\\Windows' })

      assert_equal 'C:\\Windows', request[:working_directory]
    end

    def test_the_environment_keeps_only_system_variables_under_the_sandboxs_own
      host = { 'SystemRoot' => 'C:\\Windows', 'Path' => 'C:\\bin', 'LOCALAPPDATA' => 'C:\\L', 'OPENAI_API_KEY' => 'sk' }

      _, request = on_windows(MXC.sandbox.with_env('PATH' => 'C:\\tools', 'LANG' => 'C'), env: host)

      assert_equal({ 'SystemRoot' => 'C:\\Windows', 'LOCALAPPDATA' => 'C:\\L', 'PATH' => 'C:\\tools', 'LANG' => 'C' },
                   request[:environment])
    end

    def test_auto_runs_on_process_container
      result = Preflight.stub(:windows?, true) do
        Native.stub(:run, ->(*) { outcome }) { MXC.sandbox.run('exit 0') }
      end

      assert_equal :process_container, result.backend
    end

    def test_denied_paths_need_a_backend_that_enforces_them
      appcontainer = [{ name: :processcontainer, tier: 'appcontainer-dacl', capabilities: [], warnings: [] }]
      base = [{ name: :processcontainer, tier: 'base-container', capabilities: [:filesystem_denied_paths],
                warnings: [] }]

      Preflight.stub(:windows?, true) do
        Native.stub(:backends, appcontainer) do
          error = Preflight.problem(network: false, denied: ['C:\\secret'])

          assert_instance_of UnsupportedError, error
          assert_match 'readable and writable', error.remediation
          assert_nil Preflight.problem(network: false, denied: [])
        end
        Native.stub(:backends, base) { assert_nil Preflight.problem(network: false, denied: ['C:\\secret']) }
      end
    end

    def test_allow_lists_are_unsupported
      error = Preflight.stub(:windows?, true) { Preflight.problem(network: { allow: ['pypi.org'] }) }

      assert_instance_of UnsupportedError, error
      assert_match 'network: true', error.remediation
      Preflight.stub(:windows?, true) do
        assert_nil Preflight.problem(network: true)
        assert_nil Preflight.problem(network: false)
      end
    end
  end

  class SandboxMacrosTest < Minitest::Test
    class SkillSandbox < MXC::Sandbox
      readable 'app/skills'
      writable 'tmp/skills'
      network allow: ['pypi.org']
      env 'LANG' => 'C.UTF-8'
      directory 'app/skills'
      timeout 30
      backend :bubblewrap
    end

    class StricterSandbox < SkillSandbox
      denied 'app/skills/secrets'
      network false
    end

    def test_macros_set_the_defaults_of_every_instance
      sandbox = SkillSandbox.new

      assert_instance_of SkillSandbox, sandbox
      assert_equal ['app/skills'], sandbox.readable
      assert_equal ['tmp/skills'], sandbox.writable
      assert_equal({ allow: ['pypi.org'] }, sandbox.network)
      assert_equal({ 'LANG' => 'C.UTF-8' }, sandbox.env)
      assert_equal 'app/skills', sandbox.directory
      assert_equal 30, sandbox.timeout
      assert_equal :bubblewrap, sandbox.backend
    end

    def test_instances_change_independently_of_the_class
      SkillSandbox.new.with_readable('lib').with_env('A' => '1')

      assert_equal ['app/skills'], SkillSandbox.new.readable
      assert_equal({ 'LANG' => 'C.UTF-8' }, SkillSandbox.new.env)
    end

    def test_subclasses_inherit_and_override
      sandbox = StricterSandbox.new

      assert_equal ['app/skills'], sandbox.readable
      assert_equal ['app/skills/secrets'], sandbox.denied
      refute sandbox.network
      assert_empty SkillSandbox.new.denied
    end

    def test_keyword_options_apply_on_top_of_the_macros
      assert_equal 5, SkillSandbox.new(timeout: 5).timeout
    end

    def test_macros_return_nil
      assert_nil Class.new(MXC::Sandbox).readable('a')
    end
  end
end
