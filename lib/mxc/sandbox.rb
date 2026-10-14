# frozen_string_literal: true

require 'shellwords'

module MXC
  # A sandbox policy: what a command may read, write and reach, and how long it may run.
  #
  # Setters return the sandbox, so they chain, and +nil+ resets a setting to its default:
  #
  #   sandbox = MXC.sandbox
  #     .with_readable("app/skills")
  #     .with_writable(Rails.root.join("tmp"))
  #     .with_network(allow: ["pypi.org", "*.pythonhosted.org"])
  #     .with_timeout(30)
  #   sandbox.run("python3 app/skills/build.py")
  #
  # Subclasses declare the same settings with class macros:
  #
  #   class SkillSandbox < MXC::Sandbox
  #     readable "app/skills"
  #     writable "tmp/skills"
  #     network false
  #     timeout 30
  #   end
  #
  #   SkillSandbox.new.run("python3 app/skills/build.py")
  class Sandbox
    BACKENDS = %i[auto bubblewrap seatbelt process_container].freeze # :nodoc:
    OPTIONS = %i[readable writable denied network env directory timeout backend].freeze # :nodoc:
    HOST_RESOLVER_SOCKETS = %w[/run/systemd/resolve].freeze # :nodoc:
    WINDOWS_ENV = %w[SYSTEMROOT WINDIR SYSTEMDRIVE COMSPEC PATHEXT PATH LOCALAPPDATA TEMP TMP
                     PROCESSOR_ARCHITECTURE NUMBER_OF_PROCESSORS OS].freeze # :nodoc:
    BATCH_FILE = /\.(bat|cmd)\z/i # :nodoc:
    MAX_TIMEOUT_MS = (2**32) - 1 # :nodoc:
    DEFAULTS = {
      readable: [], writable: [], denied: [], env: {}, network: false, directory: nil, timeout: nil, backend: nil
    }.freeze # :nodoc:

    class << self
      # Adds paths every instance can read.
      def readable(*paths) = configure { |sandbox| sandbox.with_readable(*paths) }

      # Adds paths every instance can read and write.
      def writable(*paths) = configure { |sandbox| sandbox.with_writable(*paths) }

      # Adds paths every instance hides, even inside readable or writable paths.
      def denied(*paths) = configure { |sandbox| sandbox.with_denied(*paths) }

      # Sets every instance's network access. Takes the same arguments as #with_network.
      def network(...) = configure { |sandbox| sandbox.with_network(...) }

      # Adds environment variables for every instance.
      def env(variables) = configure { |sandbox| sandbox.with_env(variables) }

      # Sets every instance's working directory.
      def directory(path) = configure { |sandbox| sandbox.with_directory(path) }

      # Sets every instance's timeout in seconds.
      def timeout(seconds) = configure { |sandbox| sandbox.with_timeout(seconds) }

      # Sets every instance's backend.
      def backend(name) = configure { |sandbox| sandbox.with_backend(name) }

      def defaults # :nodoc:
        @defaults ||= allocate.tap { |sandbox| sandbox.send(:inherit, self == Sandbox ? nil : superclass.defaults) }
      end

      def backend_name(name) # :nodoc:
        name = name.to_sym
        return name if BACKENDS.include?(name)

        raise ArgumentError, "unknown backend #{name.inspect}, expected one of #{BACKENDS.map(&:inspect).join(', ')}"
      end

      def duration(seconds) # :nodoc:
        return if seconds.nil?

        value = seconds.to_f
        unless value.positive?
          raise ArgumentError,
                "timeout must be a positive number of seconds, got #{seconds.inspect}"
        end

        seconds
      end

      private

      def configure
        yield defaults
        nil
      end
    end

    # Returns a new sandbox with the class's defaults, then applies +options+ through
    # the matching setters: <tt>readable:</tt>, <tt>writable:</tt>, <tt>denied:</tt>,
    # <tt>network:</tt>, <tt>env:</tt>, <tt>directory:</tt>, <tt>timeout:</tt> and <tt>backend:</tt>.
    #
    #   MXC::Sandbox.new(readable: "app/skills", network: { allow: ["pypi.org"] }, timeout: 30)
    def initialize(**options)
      unknown = options.keys - OPTIONS
      raise ArgumentError, "unknown option#{'s' if unknown.size > 1}: #{unknown.join(', ')}" if unknown.any?

      inherit(self.class.defaults)
      options.each { |name, value| apply(name, value) }
    end

    def initialize_copy(source) # :nodoc:
      super
      @settings = @settings.transform_values(&:dup)
    end

    # Returns the paths the command can read, as given.
    def readable = @settings[:readable].dup.freeze

    # Returns the paths the command can read and write, as given.
    def writable = @settings[:writable].dup.freeze

    # Returns the paths hidden from the command, as given.
    def denied = @settings[:denied].dup.freeze

    # Returns the environment variables set for the command.
    def env = @settings[:env].dup.freeze

    # Returns the network access: +false+, +true+, or <tt>{ allow: [...] }</tt> for an allow-list.
    def network = @settings[:network]

    # Returns the working directory, or nil for the default.
    def directory = @settings[:directory]

    # Returns the timeout in seconds, falling back to MXC.config.timeout.
    def timeout = @settings[:timeout] || MXC.config.timeout

    # Returns the backend, falling back to MXC.config.backend.
    def backend = @settings[:backend] || MXC.config.backend

    # Adds paths the command can read. Accepts Strings and Pathnames; relative paths
    # are expanded from the current directory when the command runs.
    def with_readable(*paths)
      add_paths(:readable, paths)
    end

    # Adds paths the command can read and write.
    def with_writable(*paths)
      add_paths(:writable, paths)
    end

    # Adds paths hidden from the command, even inside readable or writable paths.
    def with_denied(*paths)
      add_paths(:denied, paths)
    end

    # Sets network access. The default, +false+, gives the command no network at all.
    # +true+ allows any destination. <tt>allow:</tt> takes a list of hosts the command
    # may reach over HTTP and HTTPS: <tt>"pypi.org"</tt>, <tt>"*.pythonhosted.org"</tt>
    # (subdomains only), or <tt>"example.com:8443"</tt> for another port.
    #
    #   sandbox.with_network(allow: ["pypi.org", "*.pythonhosted.org"])
    def with_network(enabled = true, allow: nil)
      if allow
        raise ArgumentError, 'pass allow: or true/false, not both' unless enabled == true

        @settings[:network] = { allow: Array(allow).map(&:to_s).freeze }.freeze
      else
        raise ArgumentError, "network must be true, false or nil, got #{enabled.inspect}" unless [true, false,
                                                                                                  nil].include?(enabled)

        @settings[:network] = enabled || false
      end
      self
    end

    # Adds environment variables for the command. The sandbox starts from a minimal
    # environment, not the parent's. On Windows, that environment keeps the system
    # variables programs need to start, such as +SYSTEMROOT+ and +PATH+.
    #
    #   sandbox.with_env("LANG" => "C.UTF-8")
    def with_env(variables)
      env = @settings[:env]
      variables.nil? ? env.clear : variables.each { |name, value| env[name.to_s] = value.to_s }
      self
    end

    # Sets the directory the command starts in. The sandbox must be able to read it.
    # Without one, the command starts in <tt>/</tt>, or <tt>%SystemRoot%</tt> on Windows.
    def with_directory(path)
      @settings[:directory] = path && File.path(path)
      self
    end

    # Sets the timeout in seconds. Accepts anything that responds to +to_f+, such as
    # <tt>30</tt>, <tt>2.5</tt> or <tt>1.minute</tt>.
    def with_timeout(seconds)
      @settings[:timeout] = self.class.duration(seconds)
      self
    end

    # Sets the backend: <tt>:auto</tt> (Bubblewrap on Linux, Seatbelt on macOS,
    # ProcessContainer on Windows), <tt>:bubblewrap</tt>, <tt>:seatbelt</tt>, or
    # <tt>:process_container</tt>.
    def with_backend(name)
      @settings[:backend] = name && self.class.backend_name(name)
      self
    end

    # Runs +command+ and returns its Result once it finishes. A String runs through
    # the platform shell: <tt>sh -c</tt>, or <tt>cmd.exe /c</tt> on Windows. An Array
    # is a program and its arguments, each of which reaches the program unchanged.
    #
    # With a block, yields each Chunk of output as it arrives.
    #
    #   sandbox.run(["python3", "build.py"]) { |chunk| print chunk.content }
    def run(command, &)
      return stream(command, &) if block_given?

      outcome = StartupFailure.check!(Native.run(command_line(command), request))
      Result.new(**outcome, backend: resolved_backend)
    end

    # Starts +command+ and returns its Process without waiting for it.
    def spawn(command)
      Process.new(Native.spawn(command_line(command), request), backend: resolved_backend)
    end

    # Returns true when this host can run this sandbox, including its network policy.
    def supported?
      availability.supported?
    end

    # Returns the Availability of this sandbox on this host, with the reason and
    # remediation when it cannot run.
    def availability
      problem = Preflight.problem(network:, denied:)
      return MXC.availability(backend:) unless problem

      Availability.new(backend:, supported: false, reason: problem.message, remediation: problem.remediation)
    end

    def inspect # :nodoc:
      "#<#{self.class.name || 'MXC::Sandbox'} backend=#{backend.inspect} network=#{network.inspect} " \
        "readable=#{readable.inspect} writable=#{writable.inspect} timeout=#{timeout.inspect}>"
    end

    protected

    attr_reader :settings # :nodoc:

    private

    def inherit(source)
      @settings = source ? source.settings.transform_values(&:dup) : DEFAULTS.transform_values(&:dup)
    end

    def apply(name, value)
      case name
      when :readable, :writable, :denied then public_send(:"with_#{name}", *Array(value))
      when :network then value.is_a?(Hash) ? with_network(**value) : with_network(value)
      else public_send(:"with_#{name}", value)
      end
    end

    def add_paths(name, paths)
      list = @settings[name]
      paths == [nil] ? list.clear : list.concat(paths.flatten.map { |path| File.path(path) })
      self
    end

    def stream(command, &)
      process = spawn(command)
      finished = false
      process.each(&)
      finished = true
      process.wait
    ensure
      process&.kill unless finished
    end

    def command_line(command)
      return command_line_for_windows(command) if Preflight.windows?

      command.is_a?(Array) ? Shellwords.join(command.map(&:to_s)) : command.to_s
    end

    def command_line_for_windows(command)
      return %(cmd.exe /d /s /c "#{command}") unless command.is_a?(Array)

      program, = command
      if program.to_s.match?(BATCH_FILE)
        raise ArgumentError, 'Windows runs batch files through cmd.exe, which does not keep arguments apart. ' \
                             'Run them with a String command and quote untrusted input yourself'
      end

      command.map { |argument| WindowsArguments.quote(argument.to_s) }.join(' ')
    end

    def resolved_backend
      return backend unless backend == :auto
      return :process_container if Preflight.windows?

      Preflight.linux? ? :bubblewrap : :seatbelt
    end

    def request
      Preflight.check!(network:, denied:)
      {
        readonly: expand(readable),
        readwrite: expand(writable),
        denied: expand(denied) | hidden_resolver_sockets,
        environment:,
        working_directory:,
        timeout_ms: timeout && [(timeout.to_f * 1000).ceil, MAX_TIMEOUT_MS].min,
        backend:,
        network: network == true,
        allow: network.is_a?(Hash) ? network[:allow] : nil
      }
    end

    def expand(paths)
      paths.map { |path| native_path(File.expand_path(path)) }
    end

    def native_path(path)
      Preflight.windows? ? path.tr('/', '\\') : path
    end

    def working_directory
      return native_path(File.expand_path(directory)) if directory

      ENV.fetch('SystemRoot', nil) if Preflight.windows?
    end

    def environment
      return env unless Preflight.windows?

      system = ENV.to_h.select { |name, _| WINDOWS_ENV.include?(name.upcase) }
      system.reject { |name, _| env.keys.any? { |own| own.casecmp?(name) } }.merge(env)
    end

    def hidden_resolver_sockets
      return [] if network == true

      HOST_RESOLVER_SOCKETS.select { |path| File.exist?(path) }
    end
  end
end
