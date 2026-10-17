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
  #   sandbox.run("python3", "app/skills/convert.py", params[:filename])
  #
  # Subclasses declare the same settings with class macros:
  #
  #   class SkillSandbox < MXC::Sandbox
  #     readable "app/skills"
  #     writable "tmp/skills"
  #     network false
  #     timeout 30
  #     limits cpu_time: 60, memory: 2 * 1024**3
  #     priority :low
  #   end
  #
  #   SkillSandbox.new.run("python3 app/skills/build.py")
  class Sandbox
    BACKENDS = %i[auto bubblewrap landlock seatbelt process_container].freeze # :nodoc:
    LANDLOCK_FALLBACK = /runs on Landlock instead/ # :nodoc:
    OPTIONS = %i[readable writable denied network env directory timeout backend limits priority].freeze # :nodoc:
    HOST_RESOLVER_SOCKETS = %w[/run/systemd/resolve].freeze # :nodoc:
    WINDOWS_ENV = %w[SYSTEMROOT WINDIR SYSTEMDRIVE COMSPEC PATHEXT PATH LOCALAPPDATA TEMP TMP
                     PROCESSOR_ARCHITECTURE NUMBER_OF_PROCESSORS OS].freeze # :nodoc:
    BATCH_FILE = /\.(bat|cmd)\z/i # :nodoc:
    MAX_TIMEOUT_MS = (2**32) - 1 # :nodoc:
    LIMITS = %i[cpu_time memory processes].freeze # :nodoc:
    PRIORITIES = { normal: nil, low: 'low', lowest: 'idle' }.freeze # :nodoc:
    MEGABYTE = 1024 * 1024 # :nodoc:
    DEFAULTS = {
      readable: [], writable: [], denied: [], env: {}, network: false, directory: nil, timeout: nil, backend: nil,
      limits: {}, priority: nil
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

      # Sets every instance's resource limits. Takes the same arguments as #with_limits.
      def limits(...) = configure { |sandbox| sandbox.with_limits(...) }

      # Sets every instance's scheduling priority: <tt>:normal</tt>, <tt>:low</tt>, or <tt>:lowest</tt>.
      def priority(level) = configure { |sandbox| sandbox.with_priority(level) }

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
    # <tt>network:</tt>, <tt>env:</tt>, <tt>directory:</tt>, <tt>timeout:</tt>, <tt>backend:</tt>,
    # <tt>limits:</tt> and <tt>priority:</tt>.
    #
    #   MXC::Sandbox.new(readable: "app/skills", network: { allow: ["pypi.org"] }, timeout: 30)
    #   MXC::Sandbox.new(limits: { cpu_time: 60, memory: 2 * 1024**3 }, priority: :low)
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

    # Returns the resource limits, such as <tt>{ cpu_time: 60, memory: 2147483648 }</tt>.
    # A limit that is not set is absent.
    def limits = @settings[:limits].dup.freeze

    # Returns the scheduling priority: <tt>:normal</tt>, <tt>:low</tt>, or <tt>:lowest</tt>.
    def priority = @settings[:priority] || :normal

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
    # ProcessContainer on Windows), <tt>:bubblewrap</tt>, <tt>:landlock</tt>, <tt>:seatbelt</tt>,
    # or <tt>:process_container</tt>.
    #
    # On Linux, <tt>:auto</tt> runs on Landlock when Bubblewrap cannot create its namespaces,
    # and says so in Result#warnings. <tt>:bubblewrap</tt> never does. <tt>:landlock</tt>
    # needs Linux 6.2 or newer and runs without network access.
    def with_backend(name)
      @settings[:backend] = name && self.class.backend_name(name)
      self
    end

    # Sets resource limits. Each process the command starts gets its own CPU time and memory.
    #
    # <tt>cpu_time:</tt> is the CPU time each process may use, in seconds. It accepts
    # anything that responds to +to_f+, such as <tt>90</tt> or <tt>2.minutes</tt>, and is
    # rounded up to whole seconds on Linux and macOS. A process that uses it up is stopped.
    #
    # <tt>memory:</tt> is the memory each process may allocate, in bytes. It accepts
    # anything that responds to +to_i+, such as <tt>2 * 1024**3</tt> or
    # <tt>2.gigabytes</tt>, and is rounded up to whole megabytes. Allocations beyond it
    # fail. Not available on macOS.
    #
    # <tt>processes:</tt> is how many processes the command may run at the same time.
    # Windows only.
    #
    # A limit given as +nil+ is removed, and <tt>with_limits(nil)</tt> removes them all.
    # Raises ArgumentError for an unknown limit or a value that is not positive.
    #
    #   sandbox.with_limits(cpu_time: 2.minutes, memory: 2.gigabytes)
    def with_limits(reset = (keep = true), **limits)
      unless keep
        raise ArgumentError, "pass limits as keywords, or nil to remove them, got #{reset.inspect}" unless reset.nil?

        @settings[:limits].clear
      end
      limits.each { |name, value| set_limit(name, value) }
      self
    end

    # Sets the scheduling priority of every process the command starts: <tt>:normal</tt>
    # (the default), <tt>:low</tt> (nice 10 on Linux and macOS, below normal on
    # Windows), or <tt>:lowest</tt> (nice 19, or idle on Windows).
    def with_priority(level)
      @settings[:priority] = level && priority_name(level)
      self
    end

    # Runs +command+ and returns its Result once it finishes. Like Kernel#system, one
    # String runs through the platform shell: <tt>sh -c</tt>, or <tt>cmd.exe /d /s /c</tt>
    # on Windows. Two or more Strings are a program and its arguments, and each argument
    # reaches the program unchanged, without a shell.
    #
    # With a block, yields each Chunk of output as it arrives.
    #
    #   sandbox.run("python3 build.py && ls dist")
    #   sandbox.run("python3", "convert.py", params[:filename])
    #   sandbox.run("python3", "build.py") { |chunk| print chunk.content }
    #
    # Raises ArgumentError without a command or when given an Array. On Windows, it also
    # raises ArgumentError for a program and arguments that start a +.bat+ or +.cmd+ file,
    # because Windows runs those through +cmd.exe+, which splits the arguments again.
    def run(*command, &)
      return stream(*command, &) if block_given?

      outcome = StartupFailure.check!(Native.run(command_line(command), request))
      Result.new(**outcome, backend: resolved_backend(outcome[:warnings]))
    end

    # Starts +command+ and returns its Process without waiting for it. Takes the command
    # the same way as #run.
    #
    #   sandbox.spawn("python3", "-i", "-q")
    def spawn(*command)
      native = Native.spawn(command_line(command), request)
      Process.new(native, backend: resolved_backend(native.warnings))
    end

    # Returns true when this host can run this sandbox, including its network policy.
    def supported?
      availability.supported?
    end

    # Returns the Availability of this sandbox on this host, with the reason and
    # remediation when it cannot run.
    def availability
      problem = Preflight.problem(network:, denied:, resources:, backend:)
      host = MXC.availability(backend:) unless problem
      problem ||= Preflight.problem(network:, backend: :landlock) if host&.runs_on == :landlock
      return host unless problem

      Availability.new(backend:, supported: false, reason: problem.message, remediation: problem.remediation)
    end

    def inspect # :nodoc:
      resources = " limits=#{limits.inspect} priority=#{priority.inspect}" if self.resources
      "#<#{self.class.name || 'MXC::Sandbox'} backend=#{backend.inspect} network=#{network.inspect} " \
        "readable=#{readable.inspect} writable=#{writable.inspect} timeout=#{timeout.inspect}#{resources}>"
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
      when :limits then value.nil? ? with_limits(nil) : with_limits(**value)
      else public_send(:"with_#{name}", value)
      end
    end

    def set_limit(name, value)
      unless LIMITS.include?(name)
        raise ArgumentError, "unknown limit #{name.inspect}, expected one of #{LIMITS.map(&:inspect).join(', ')}"
      end
      return @settings[:limits].delete(name) if value.nil?

      @settings[:limits][name] = positive_limit(name, value)
    end

    def positive_limit(name, value)
      amount = limit_amount(name, value)
      raise ArgumentError, "#{name} must be a positive number, got #{value.inspect}" unless amount&.positive?

      value
    end

    def limit_amount(name, value)
      return (value if value.is_a?(Integer)) if name == :processes

      conversion = name == :cpu_time ? :to_f : :to_i
      value.public_send(conversion) if value.respond_to?(conversion)
    end

    def priority_name(level)
      level = level.to_sym
      return level if PRIORITIES.key?(level)

      raise ArgumentError,
            "unknown priority #{level.inspect}, expected one of #{PRIORITIES.keys.map(&:inspect).join(', ')}"
    end

    def add_paths(name, paths)
      list = @settings[name]
      paths == [nil] ? list.clear : list.concat(paths.flatten.map { |path| File.path(path) })
      self
    end

    def stream(*command, &)
      process = spawn(*command)
      finished = false
      process.each(&)
      finished = true
      process.wait
    ensure
      process&.kill unless finished
    end

    def command_line(command)
      arguments = command_arguments(command)
      return command_line_for_windows(arguments) if Preflight.windows?

      arguments.one? ? arguments.first : Shellwords.join(arguments)
    end

    def command_arguments(command)
      raise ArgumentError, 'no command given' if command.empty?
      if command.any?(Array)
        raise ArgumentError, 'pass the program and its arguments as separate Strings, ' \
                             'as in run("python3", "build.py"), not as an Array'
      end

      command.map { |argument| String.try_convert(argument) || File.path(argument) }
    end

    def command_line_for_windows(arguments)
      return %(cmd.exe /d /s /c "#{arguments.first}") if arguments.one?

      if arguments.first.match?(BATCH_FILE)
        raise ArgumentError, 'Windows runs batch files through cmd.exe, which does not keep arguments apart. ' \
                             'Run them with one String and quote untrusted input yourself'
      end

      arguments.map { |argument| WindowsArguments.quote(argument) }.join(' ')
    end

    def resolved_backend(warnings)
      return backend unless backend == :auto
      return :process_container if Preflight.windows?
      return :seatbelt unless Preflight.linux?

      warnings.any?(LANDLOCK_FALLBACK) ? :landlock : :bubblewrap
    end

    def request
      Preflight.check!(network:, denied:, resources:, backend:)
      {
        readonly: expand(readable),
        readwrite: expand(writable),
        denied: expand(denied) | hidden_resolver_sockets,
        environment:,
        working_directory:,
        timeout_ms: timeout && [(timeout.to_f * 1000).ceil, MAX_TIMEOUT_MS].min,
        backend:,
        network: network == true,
        allow: network.is_a?(Hash) ? network[:allow] : nil,
        resources:
      }
    end

    protected

    # The resource limits as MXC takes them, or nil when there are none.
    def resources
      limits = @settings[:limits]
      return if limits.empty? && priority == :normal

      {
        cpu_time_ms: limits[:cpu_time] && (limits[:cpu_time].to_f * 1000).ceil,
        memory_mb: limits[:memory] && -(-limits[:memory].to_i / MEGABYTE),
        max_processes: limits[:processes],
        priority: PRIORITIES.fetch(priority)
      }.compact
    end

    private

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
