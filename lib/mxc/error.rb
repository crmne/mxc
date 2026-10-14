# frozen_string_literal: true

module MXC
  # Raised when MXC cannot start or finish a sandbox.
  #
  #   rescue MXC::Error => e
  #     e.code        # => :backend_error
  #     e.remediation # => "Install bubblewrap"
  class Error < StandardError
    # Returns MXC's error code as a Symbol, such as <tt>:backend_unavailable</tt>.
    attr_reader :code

    # Returns a suggestion for fixing the problem, or nil.
    attr_reader :remediation

    # Returns the operation that failed, as MXC names it, or nil.
    attr_reader :operation

    # Returns the operating system's own error code, or nil.
    attr_reader :native_code

    # Returns a new Error with +message+ and optional details.
    def initialize(message = nil, code: nil, remediation: nil, operation: nil, native_code: nil)
      super(message)
      @code = code
      @remediation = remediation
      @operation = operation
      @native_code = native_code
    end
  end

  # Raised when this host cannot run the sandbox as configured, such as when Bubblewrap is
  # missing, user namespaces are blocked, or a network policy needs tools that are not installed.
  # Its +remediation+ says what to change.
  class UnsupportedError < Error; end
end
