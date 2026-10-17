# frozen_string_literal: true

begin
  require "mxc/#{RUBY_VERSION[/\d+\.\d+/]}/mxc"
rescue LoadError
  require 'mxc/mxc'
end

module MXC
  module Native # :nodoc:
    UNSUPPORTED_CODES = %i[backend_unavailable unsupported_containment].freeze
    BACKEND_NAMES = { processcontainer: :process_container }.freeze
    MISSING_BUBBLEWRAP = /bwrap\) is not installed/
    INSTALL_BUBBLEWRAP = 'Install Bubblewrap 0.5.0 or newer (Debian/Ubuntu: apt-get install bubblewrap; ' \
                         'Fedora: dnf install bubblewrap; Arch: pacman -S bubblewrap)'

    def self.backend_attributes
      backends.map { |attributes| attributes.merge(name: BACKEND_NAMES.fetch(attributes[:name], attributes[:name])) }
    end

    def self.error(message, code: nil, remediation: nil, **)
      if message.match?(MISSING_BUBBLEWRAP)
        UnsupportedError.new(message, code: :backend_unavailable, remediation: remediation || INSTALL_BUBBLEWRAP, **)
      elsif UNSUPPORTED_CODES.include?(code)
        UnsupportedError.new(message, code:, remediation: remediation || StartupFailure.hint(message), **)
      else
        Error.new(message, code:, remediation:, **)
      end
    end
  end
end
