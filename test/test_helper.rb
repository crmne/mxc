# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'mxc'

require 'minitest/autorun'
require 'minitest/mock'
require 'pathname'
require 'tmpdir'

module SandboxHelpers
  OUTCOME = { timed_out: false, exit_code: 0, stdout: '', stderr: '', warnings: [], blocked: [] }.freeze
  SETUP_FAILURE = 'Bubblewrap: bwrap could not set up the sandbox and never started the workload'

  def skip_unless_supported
    skip "no sandbox on this host: #{MXC.availability.reason}" unless MXC.supported?
  end

  def skip_unless_network
    skip_unless_supported
    problem = MXC::Preflight.problem(network: true)
    skip problem.message if problem
  end

  def outcome(**overrides)
    OUTCOME.merge(overrides)
  end

  def setup_failure(stderr)
    outcome(exit_code: nil, failure: SETUP_FAILURE, stderr:)
  end

  def capture_request(sandbox, *command)
    captured = nil
    MXC::Native.stub(:run, lambda { |line, request|
      captured = [line, request]
      outcome
    }) do
      MXC::Preflight.stub(:check!, nil) { sandbox.run(*command.empty? ? ['true'] : command) }
    end
    captured
  end
end

module Minitest
  class Test
    include SandboxHelpers

    def setup
      super
      @config = MXC.config.dup
    end

    def teardown
      MXC.instance_variable_set(:@config, @config)
      super
    end
  end
end
