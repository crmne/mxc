# frozen_string_literal: true

module MXC
  # The outcome of a command that ran in a sandbox.
  #
  #   result = MXC.run("python3 build.py")
  #   result.success? # => true
  #   result.stdout   # => "built 3 files\n"
  class Result
    # Returns everything the command wrote to standard output.
    attr_reader :stdout

    # Returns everything the command wrote to standard error.
    attr_reader :stderr

    # Returns the exit code, or nil when the command timed out.
    attr_reader :exit_code

    # Returns MXC's warnings about the sandbox, as Strings.
    attr_reader :warnings

    # Returns the <tt>host:port</tt> destinations the network allow-list refused.
    attr_reader :blocked

    # Returns the backend that ran the command, such as <tt>:bubblewrap</tt>.
    attr_reader :backend

    # Returns the CPU time the command used, user and system, in seconds as a Float. It
    # includes every process the command started and waited for. Returns nil unless the
    # sandbox has limits or a priority.
    attr_reader :cpu_time

    # Returns the limit the command ran into: <tt>:cpu_time</tt>, <tt>:memory</tt>,
    # <tt>:processes</tt>, or nil. Linux and macOS report <tt>:cpu_time</tt> only, because a
    # program that cannot allocate memory decides itself how to fail.
    attr_reader :limit_exceeded

    def initialize(stdout:, stderr:, exit_code:, timed_out:, warnings:, blocked:, backend:, # :nodoc:
                   cpu_time: nil, limit_exceeded: nil)
      @stdout = text(stdout)
      @stderr = text(stderr)
      @exit_code = exit_code
      @timed_out = timed_out
      @warnings = warnings.freeze
      @blocked = blocked.freeze
      @backend = backend
      @cpu_time = cpu_time
      @limit_exceeded = limit_exceeded
    end

    # Returns true when the command exited with status 0 before its timeout.
    def success?
      !timed_out? && exit_code.zero?
    end

    # Returns true when the command ran out of time and was stopped.
    def timed_out?
      @timed_out
    end

    # Returns the result as a Hash.
    def to_h
      { stdout:, stderr:, exit_code:, timed_out: timed_out?, warnings:, blocked:, backend:, cpu_time:,
        limit_exceeded: }
    end

    def inspect # :nodoc:
      usage = " cpu_time=#{cpu_time.round(3)} limit_exceeded=#{limit_exceeded.inspect}" if cpu_time
      "#<MXC::Result exit_code=#{exit_code.inspect} timed_out=#{timed_out?}#{usage} backend=#{backend.inspect}>"
    end

    private

    def text(bytes)
      bytes.dup.force_encoding(Encoding.default_external).freeze
    end
  end
end
