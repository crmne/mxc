# frozen_string_literal: true

module MXC
  module WindowsArguments # :nodoc:
    SPECIAL = /[\s"]/

    module_function

    # Quotes +argument+ so CommandLineToArgvW and the C runtime read it back unchanged.
    def quote(argument)
      return '""' if argument.empty?
      return argument unless argument.match?(SPECIAL)

      quoted = argument.gsub(/(\\*)"/) { "#{Regexp.last_match(1) * 2}\\\"" }
      "\"#{quoted.sub(/(\\+)\z/) { Regexp.last_match(1) * 2 }}\""
    end
  end
end
