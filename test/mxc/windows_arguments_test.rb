# frozen_string_literal: true

require 'test_helper'

module MXC
  class WindowsArgumentsTest < Minitest::Test
    ARGUMENTS = ['plain', '', 'a b', "tab\there", 'say "hi"', 'dir\\', 'dir with space\\', 'a\\\\"b',
                 '\\\\server\\share', '"', '\\"', 'trailing\\\\'].freeze

    def test_leaves_plain_arguments_alone
      assert_equal 'plain', WindowsArguments.quote('plain')
      assert_equal 'C:\\dir\\file.txt', WindowsArguments.quote('C:\\dir\\file.txt')
    end

    def test_quotes_spaces_quotes_and_empty_arguments
      assert_equal '""', WindowsArguments.quote('')
      assert_equal '"a b"', WindowsArguments.quote('a b')
      assert_equal '"say \\"hi\\""', WindowsArguments.quote('say "hi"')
      assert_equal '"dir with space\\\\"', WindowsArguments.quote('dir with space\\')
      assert_equal '"a\\\\\\\\\\"b"', WindowsArguments.quote('a\\\\"b')
    end

    def test_command_line_to_argv_reads_them_back_unchanged
      skip 'CommandLineToArgvW is a Windows API' unless Preflight.windows?

      line = (['program.exe'] + ARGUMENTS).map { |argument| WindowsArguments.quote(argument) }.join(' ')

      assert_equal ARGUMENTS, command_line_to_argv(line).drop(1)
    end

    private

    def command_line_to_argv(line)
      require 'fiddle/import'
      shell32 = Fiddle.dlopen('shell32')
      kernel32 = Fiddle.dlopen('kernel32')
      parse = Fiddle::Function.new(shell32['CommandLineToArgvW'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                                   Fiddle::TYPE_VOIDP)
      free = Fiddle::Function.new(kernel32['LocalFree'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      count = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT, Fiddle::RUBY_FREE)
      argv = parse.call("#{line}\0".encode('UTF-16LE'), count)
      arguments = Array.new(count[0, Fiddle::SIZEOF_INT].unpack1('l')) do |index|
        wide_string((argv + (index * Fiddle::SIZEOF_VOIDP)).ptr)
      end
      free.call(argv)
      arguments
    end

    def wide_string(pointer)
      length = 0
      length += 2 until pointer[length, 2] == "\0\0"
      pointer[0, length].force_encoding('UTF-16LE').encode('UTF-8')
    end
  end
end
