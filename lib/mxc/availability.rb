# frozen_string_literal: true

module MXC
  # Whether this host can start a sandbox, and why not, as returned by MXC.availability.
  #
  #   availability = MXC.availability
  #   availability.supported?  # => false
  #   availability.remediation # => "Unprivileged user namespaces are blocked. ..."
  class Availability
    # Returns the backend that was checked.
    attr_reader :backend

    # Returns why a sandbox cannot start, or nil when it can.
    attr_reader :reason

    # Returns a suggestion for making the host supported, or nil.
    attr_reader :remediation

    def self.probe(backend) # :nodoc:
      result = Sandbox.new(backend:, timeout: 10).run('exit 0')
      return new(backend:, supported: true) if result.success?

      outcome = result.timed_out? ? 'timed out' : "exited with #{result.exit_code}"
      new(backend:, supported: false, reason: "A sandboxed `exit 0` #{outcome}: #{result.stderr.strip}")
    rescue Error => e
      new(backend:, supported: false, reason: e.message, remediation: e.remediation)
    end

    def initialize(backend:, supported:, reason: nil, remediation: nil) # :nodoc:
      @backend = backend
      @supported = supported
      @reason = reason
      @remediation = remediation
    end

    # Returns true when a sandbox can start.
    def supported?
      @supported
    end

    def inspect # :nodoc:
      "#<MXC::Availability backend=#{backend.inspect} supported=#{supported?} reason=#{reason.inspect}>"
    end
  end
end
