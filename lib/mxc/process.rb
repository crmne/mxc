# frozen_string_literal: true

module MXC
  # A command running in a sandbox, as returned by Sandbox#spawn.
  #
  #   process = MXC.sandbox.spawn("python3 -i")
  #   process.write("print(6 * 7)\n")
  #   process.close_write
  #   process.each { |chunk| print chunk.content }
  #   process.wait # => #<MXC::Result exit_code=0 ...>
  #
  # Output is read in the background from the start, so the command never blocks on a full pipe,
  # and the timeout applies whether or not anything waits.
  class Process
    READ_SIZE = 16 * 1024 # :nodoc:
    STREAMS = %i[stdout stderr].freeze # :nodoc:

    def initialize(native, backend:) # :nodoc:
      @native = native
      @backend = backend
      @chunks = Thread::Queue.new
      @output = STREAMS.to_h { |stream| [stream, String.new(encoding: Encoding::BINARY)] }
      @lock = Mutex.new
      @streams_lock = Mutex.new
      @open_streams = STREAMS.size
      @readers = STREAMS.map { |stream| background { read(stream) } }
      @waiter = background { @native.wait }
    end

    # Returns the operating system process id of the sandbox.
    def pid
      @native.pid
    end

    # Writes +data+ to the command's standard input and returns the number of bytes written.
    def write(data)
      @native.write(data.to_s)
    end

    # Closes the command's standard input, so it reads end of file.
    def close_write
      @native.close_stdin
      nil
    end

    # Yields each Chunk of output as it arrives, until the command closes both output streams.
    # Returns an Enumerator without a block.
    def each
      return enum_for(:each) unless block_given?

      while (chunk = @chunks.pop)
        yield chunk
      end
      self
    end

    # Stops the command and everything it started.
    def kill
      @native.kill
      nil
    end

    # Closes standard input, waits for the command to finish, and returns its Result.
    #
    # Raises Error, or UnsupportedError for a host problem, when the sandbox itself could not start.
    def wait
      @lock.synchronize { @result || (@result = finish) }
    end

    def inspect # :nodoc:
      "#<MXC::Process pid=#{pid} backend=#{@backend.inspect}>"
    end

    private

    def background(&)
      Thread.new(&).tap { |thread| thread.report_on_exception = false }
    end

    def read(stream)
      reader = :"read_#{stream}"
      while (data = @native.public_send(reader, READ_SIZE))
        @output[stream] << data
        @chunks << Chunk.new(stream:, content: data.dup.force_encoding(Encoding.default_external).freeze)
      end
    rescue IOError
      nil
    ensure
      @streams_lock.synchronize { @chunks.close if (@open_streams -= 1).zero? }
    end

    def finish
      close_write
      outcome = @waiter.value
      @readers.each(&:join)
      outcome = outcome.merge(stdout: @output[:stdout], stderr: @output[:stderr])
      Result.new(**StartupFailure.check!(outcome), backend: @backend)
    end
  end
end
