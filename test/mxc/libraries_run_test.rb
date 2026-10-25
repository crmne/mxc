# frozen_string_literal: true

require 'test_helper'
require 'fileutils'

module MXC
  class LibrariesRunTest < Minitest::Test
    LIBRARY = 'int answer(void) { return 42; }'
    PROGRAM = 'int answer(void); int main(void) { return answer() == 42 ? 0 : 1; }'
    LOADER = <<~C
      #include <dlfcn.h>
      int main(int argc, char **argv) {
        void *bundle = dlopen(argv[1], RTLD_NOW);
        int (*check)(void) = bundle ? (int (*)(void))dlsym(bundle, "check") : 0;
        return check && check() == 42 ? 0 : 1;
      }
    C
    BUNDLE = 'int answer(void); int check(void) { return answer(); }'

    def setup
      super
      skip 'needs macOS with the Command Line Tools' unless Libraries.available?
      skip_unless_supported
      @root = File.realpath(Dir.mktmpdir('mxc-libraries-run'))
      @library = compile(LIBRARY, 'vendor/lib/libanswer.dylib', '-dynamiclib',
                         '-install_name', File.join(@root, 'vendor/lib/libanswer.dylib'))
    end

    def teardown
      FileUtils.rm_rf(@root) if @root
      super
    end

    def test_a_program_loads_the_libraries_it_links_outside_the_readable_paths
      program = compile(PROGRAM, 'app/answer', '-L', File.dirname(@library), '-lanswer')

      result = MXC.sandbox.with_readable(File.dirname(program)).run(program)

      assert_equal 0, result.exit_code, result.stderr
    end

    def test_only_the_library_files_become_readable
      program = compile(PROGRAM, 'app/answer', '-L', File.dirname(@library), '-lanswer')
      neighbour = File.join(File.dirname(@library), 'notes.txt')
      File.write(neighbour, 'private')
      sandbox = MXC.sandbox.with_libraries_of(program)

      assert_equal 0, sandbox.run('/bin/cat', @library).exit_code
      refute_equal 0, sandbox.run('/bin/cat', neighbour).exit_code
      refute_equal 0, sandbox.run('/bin/ls', File.dirname(@library)).exit_code
    end

    def test_a_program_opens_a_bundle_whose_libraries_it_was_given
      loader = compile(LOADER, 'app/loader')
      bundle = compile(BUNDLE, 'app/ext/check.bundle', '-bundle', '-L', File.dirname(@library), '-lanswer')
      sandbox = MXC.sandbox.with_readable(File.dirname(loader))

      refute_equal 0, sandbox.run(loader, bundle).exit_code
      assert_equal 0, sandbox.with_libraries_of(bundle).run(loader, bundle).exit_code
    end

    private

    def compile(source, output, *flags)
      output = File.join(@root, output)
      FileUtils.mkdir_p(File.dirname(output))
      file = "#{output}.c"
      File.write(file, source)

      assert system('xcrun', 'clang', '-o', output, file, *flags), "could not compile #{output}"
      output
    end
  end
end
