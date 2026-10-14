# frozen_string_literal: true

module MXC
  # A piece of output from a running sandbox, as passed to the block of Sandbox#run and Process#each.
  #
  #   sandbox.run("python3 build.py") { |chunk| print chunk.content }
  class Chunk
    # Returns the stream the output came from: <tt>:stdout</tt> or <tt>:stderr</tt>.
    attr_reader :stream

    # Returns the output as a String.
    attr_reader :content

    def initialize(stream:, content:) # :nodoc:
      @stream = stream
      @content = content
    end

    # Returns true when the chunk came from standard output.
    def stdout?
      stream == :stdout
    end

    # Returns true when the chunk came from standard error.
    def stderr?
      stream == :stderr
    end

    def inspect # :nodoc:
      "#<MXC::Chunk stream=#{stream.inspect} content=#{content.inspect}>"
    end
  end
end
