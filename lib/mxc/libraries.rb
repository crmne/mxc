# frozen_string_literal: true

require 'open3'

module MXC
  # Finds the shared libraries programs load, directly or through other
  # libraries, so a sandbox can read them. Only macOS needs this: Seatbelt
  # sandboxes read the system's libraries but not those a package manager
  # installs, such as Homebrew's, which a program like Ruby may link. The
  # libraries come from the programs' load commands, read with otool from
  # the Command Line Tools. Without them nothing is found, because
  # /usr/bin/otool would offer to install them instead.
  module Libraries # :nodoc:
    OTOOL = '/usr/bin/otool'
    XCODE_SELECT = '/usr/bin/xcode-select'
    SYSTEM = %w[/usr/lib/ /System/ /Library/].freeze
    TOKEN = %r{\A@(loader_path|executable_path|rpath)/}

    @links = {}
    @lock = Mutex.new

    class << self
      # Returns the real directories of the libraries +binaries+ load
      # outside the system's own, empty where none are needed or otool is
      # missing. +executable+ is the program that loads them, for
      # libraries named relative to it.
      def directories(binaries, executable: nil)
        return [] if binaries.empty? || !available?

        libraries(binaries, executable).map { |library| File.dirname(library) }.uniq
      end

      # Returns true when this host can list a program's libraries.
      def available?
        return @available if defined?(@available)

        @available = RUBY_PLATFORM.include?('darwin') && File.executable?(OTOOL) && developer_tools?
      end

      private

      def libraries(binaries, executable)
        roots = binaries.filter_map { |binary| real_path(binary) }
        links_of(roots)
        found = {}
        roots.each { |root| visit(root, executable || root, [], found) }
        found.keys
      end

      def visit(path, executable, inherited, found)
        dependencies(path, links_of([path]).fetch(path), executable, inherited).each do |library, rpaths|
          next if found.key?(library)

          found[library] = true
          visit(library, executable, rpaths, found)
        end
      end

      def developer_tools?
        system(XCODE_SELECT, '-p', out: File::NULL, err: File::NULL) == true
      end

      def dependencies(path, links, executable, inherited)
        rpaths = links[:rpaths].filter_map { |rpath| expand(rpath, path, executable) } + inherited
        links[:libraries].filter_map do |name|
          next if system?(name)

          library = locate(name, path, executable, rpaths)
          [library, rpaths] if library && !system?(library)
        end
      end

      def locate(name, loader, executable, rpaths)
        relative = name.delete_prefix('@rpath/')
        candidates = if relative == name
                       [expand(name, loader, executable)]
                     else
                       rpaths.map { |rpath| File.join(rpath, relative) }
                     end
        candidates.compact.lazy.filter_map { |candidate| real_path(candidate) }.first
      end

      def expand(name, loader, executable)
        token = name[TOKEN, 1]
        return name unless token
        return if token == 'rpath'

        base = token == 'loader_path' ? loader : executable
        File.expand_path(name.sub(TOKEN, ''), File.dirname(base))
      end

      def system?(path)
        path.start_with?(*SYSTEM)
      end

      def real_path(path)
        path = File.realpath(path)
        path if File.file?(path)
      rescue SystemCallError
        nil
      end

      def links_of(paths)
        @lock.synchronize do
          missing = paths.reject { |path| @links.key?(path) }
          @links.merge!(LoadCommands.parse(otool(missing), missing)) if missing.any?
          @links.slice(*paths)
        end
      end

      def otool(paths)
        output, = Open3.capture2(OTOOL, '-l', *paths, err: File::NULL)
        output
      rescue SystemCallError
        ''
      end
    end
  end
end
