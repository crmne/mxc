# frozen_string_literal: true

module MXC
  # A sandbox backend MXC found on this host, as returned by MXC.backends.
  #
  #   MXC.backends.first.name # => :bubblewrap
  class Backend
    # Returns the backend's name, such as <tt>:bubblewrap</tt> or <tt>:seatbelt</tt>.
    attr_reader :name

    # Returns the isolation tier MXC reports for the backend, or nil when it has none.
    attr_reader :tier

    # Returns the optional capabilities MXC reports for the backend, as Symbols.
    attr_reader :capabilities

    # Returns MXC's explanations for capabilities the backend lacks on this host.
    attr_reader :warnings

    def initialize(name:, tier: nil, capabilities: [], warnings: []) # :nodoc:
      @name = name
      @tier = tier
      @capabilities = capabilities.freeze
      @warnings = warnings.freeze
    end

    # Returns true when the backend reports +capability+, such as <tt>:proxy_enforcement</tt>.
    def supports?(capability)
      capabilities.include?(capability)
    end

    def inspect # :nodoc:
      "#<MXC::Backend name=#{name.inspect} tier=#{tier.inspect} capabilities=#{capabilities.inspect}>"
    end
  end
end
