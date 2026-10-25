# frozen_string_literal: true

module MXC
  # Reads the libraries and run paths of Mach-O files from the load
  # commands <tt>otool -l</tt> lists, with every architecture of a
  # universal file together.
  module LoadCommands # :nodoc:
    LOAD = /\A\s*cmd LC_(?:LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB)\z/
    RPATH = /\A\s*cmd LC_RPATH\z/
    COMMAND = /\A\s*cmd /
    VALUE = /\A\s*(?:name|path) (.+) \(offset \d+\)\z/
    ARCHITECTURE = / \(architecture [^)]+\)\z/

    class << self
      # Returns, for each of +paths+, the install names of the libraries it
      # loads and its run paths, as <tt>{ libraries: [...], rpaths: [...] }</tt>.
      def parse(output, paths)
        links = paths.to_h { |path| [path, { libraries: [], rpaths: [] }] }
        current = kind = nil
        output.each_line(chomp: true) do |line|
          if links.key?(header = header_path(line))
            current = links[header]
            kind = nil
          elsif current
            kind = record(current, kind, line)
          end
        end
        links
      end

      private

      def record(links, kind, line)
        return :libraries if line.match?(LOAD)
        return :rpaths if line.match?(RPATH)
        return if line.match?(COMMAND)

        value = line[VALUE, 1] if kind
        return kind unless value

        links[kind] << value
        nil
      end

      def header_path(line)
        line.delete_suffix(':').sub(ARCHITECTURE, '') if line.end_with?(':') && !line.start_with?(' ', "\t")
      end
    end
  end
end
