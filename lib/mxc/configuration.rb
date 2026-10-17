# frozen_string_literal: true

module MXC
  # Global defaults for every sandbox. Change them with MXC.configure.
  class Configuration
    # Returns the default backend, <tt>:auto</tt> unless changed.
    attr_reader :backend

    # Returns the default timeout in seconds, or nil for none.
    attr_reader :timeout

    # Returns a Configuration with the built-in defaults.
    def initialize
      @backend = :auto
      @timeout = nil
    end

    # Sets the default backend: <tt>:auto</tt>, <tt>:bubblewrap</tt>, <tt>:landlock</tt>,
    # <tt>:seatbelt</tt>, or <tt>:process_container</tt>.
    def backend=(name)
      @backend = Sandbox.backend_name(name)
    end

    # Sets the default timeout in seconds. Accepts anything that responds to +to_f+, or nil for none.
    def timeout=(seconds)
      @timeout = Sandbox.duration(seconds)
    end
  end
end
