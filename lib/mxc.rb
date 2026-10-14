# frozen_string_literal: true

require 'mxc/version'
require 'mxc/error'
require 'mxc/configuration'
require 'mxc/native'
require 'mxc/preflight'
require 'mxc/startup_failure'
require 'mxc/chunk'
require 'mxc/result'
require 'mxc/backend'
require 'mxc/availability'
require 'mxc/process'
require 'mxc/windows_arguments'
require 'mxc/sandbox'

# Runs commands in sandboxes through Microsoft's MXC.
#
#   result = MXC.run("python3 build.py", readable: "app/skills", writable: "tmp/out", timeout: 30)
#   result.stdout
module MXC
  @availability = {}
  @availability_lock = Mutex.new

  class << self
    # Returns the global Configuration.
    def config
      @config ||= Configuration.new
    end

    # Yields the global Configuration to change the defaults every sandbox starts from.
    #
    #   MXC.configure do |config|
    #     config.timeout = 60
    #   end
    def configure
      yield config
    end

    # Returns a new Sandbox, optionally configured with the same keywords as Sandbox.new.
    def sandbox(**)
      Sandbox.new(**)
    end

    # Runs +command+ in a new sandbox and returns its Result. Takes the command the same
    # way as Sandbox#run, one String for the shell or a program and its arguments, and the
    # same keywords as Sandbox.new. A block receives each Chunk of output as it arrives.
    #
    #   MXC.run("python3 build.py", readable: "app/skills", timeout: 30)
    #   MXC.run("python3", "convert.py", params[:filename], readable: "app/skills")
    def run(*command, **, &)
      sandbox(**).run(*command, &)
    end

    # Starts +command+ in a new sandbox and returns its Process. Takes the command the
    # same way as Sandbox#run, and the same keywords as Sandbox.new.
    #
    #   MXC.spawn("python3", "-i", "-q", timeout: 60)
    def spawn(*command, **)
      sandbox(**).spawn(*command)
    end

    # Returns true when this host can start a sandbox with +backend+.
    #
    # The answer comes from starting one real sandbox, once per backend and process.
    def supported?(backend: config.backend)
      availability(backend:).supported?
    end

    # Returns the Availability of +backend+ on this host, with the reason and remediation
    # when it is unsupported. Pass <tt>refresh: true</tt> to probe the host again.
    def availability(backend: config.backend, refresh: false)
      backend = Sandbox.backend_name(backend)
      @availability_lock.synchronize do
        @availability.delete(backend) if refresh
        @availability[backend] ||= Availability.probe(backend)
      end
    end

    # Returns the sandbox backends MXC finds on this host, as Backend objects.
    def backends
      Native.backend_attributes.map { |attributes| Backend.new(**attributes) }
    end

    # Returns true when this host supports +capability+ with the configured backend.
    #
    # +capability+ is <tt>:network</tt> for unrestricted network access,
    # <tt>:network_policy</tt> for host allow-lists, or any capability a Backend reports.
    def supports?(capability)
      return false unless supported?

      case capability
      when :network then Preflight.problem(network: true).nil?
      when :network_policy then Preflight.problem(network: { allow: [] }).nil? && proxy_enforcement?
      else configured_backends.any? { |backend| backend.supports?(capability) }
      end
    end

    private

    def proxy_enforcement?
      !Preflight.linux? || configured_backends.any? { |backend| backend.supports?(:proxy_enforcement) }
    end

    def configured_backends
      backends.select { |backend| config.backend == :auto || backend.name == config.backend }
    end
  end
end
