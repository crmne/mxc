# frozen_string_literal: true

require 'test_helper'
require 'fileutils'

module MXC
  class LibrariesTest < Minitest::Test
    def setup
      super
      @root = File.realpath(Dir.mktmpdir('mxc-libraries'))
    end

    def teardown
      FileUtils.rm_rf(@root)
      super
    end

    def test_finds_the_real_directories_of_libraries_and_their_own_libraries
      program = file('bin/tool')
      one = file('Cellar/one/1.0/lib/libone.dylib')
      two = file('Cellar/one/1.0/lib/libtwo.dylib')
      three = file('Cellar/three/2.0/lib/libthree.dylib')
      link('lib/libone.dylib', one)
      link('opt/three', File.join(@root, 'Cellar/three/2.0'))
      load_commands = {
        program => { libraries: ['/usr/lib/libSystem.B.dylib', '@rpath/libone.dylib'],
                     rpaths: ['@executable_path/../lib'] },
        one => { libraries: ['@loader_path/libtwo.dylib', File.join(@root, 'opt/three/lib/libthree.dylib'),
                             '/nonexistent/libgone.dylib'] },
        two => {},
        three => { libraries: ['/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation'] }
      }

      directories = with_otool(load_commands) { Libraries.directories([program]) }

      assert_equal [File.join(@root, 'Cellar/one/1.0/lib'), File.join(@root, 'Cellar/three/2.0/lib')],
                   directories
    end

    def test_reads_every_architecture_of_a_universal_binary
      program = file('bin/universal')
      library = file('Cellar/fat/lib/libfat.dylib')
      output = "#{program} (architecture x86_64):\n#{commands(libraries: [library])}" \
               "#{program} (architecture arm64):\n#{commands(libraries: [library])}#{library}:\n"

      directories = Libraries.stub(:available?, true) do
        Libraries.stub(:otool, output) { Libraries.directories([program]) }
      end

      assert_equal [File.dirname(library)], directories
    end

    def test_resolves_executable_paths_against_the_program_that_loads_them
      program = file('bin/ruby')
      extension = file('ext/psych.bundle')
      library = file('bin/libs/libyaml.dylib')
      load_commands = { extension => { libraries: ['@executable_path/libs/libyaml.dylib'] }, program => {} }

      directories = with_otool(load_commands) { Libraries.directories([extension], executable: program) }

      assert_equal [File.dirname(library)], directories
    end

    def test_finds_nothing_where_libraries_cannot_be_listed
      program = file('bin/tool')

      directories = Libraries.stub(:available?, false) do
        Libraries.stub(:otool, ->(*) { flunk 'otool ran' }) { Libraries.directories([program]) }
      end

      assert_empty directories
    end

    def test_needs_macos_and_the_command_line_tools
      Libraries.remove_instance_variable(:@available) if Libraries.instance_variable_defined?(:@available)

      if RUBY_PLATFORM.include?('darwin')
        assert_equal system('/usr/bin/xcode-select', '-p', out: File::NULL, err: File::NULL) == true,
                     Libraries.available?
      else
        refute_predicate Libraries, :available?
      end
    ensure
      Libraries.remove_instance_variable(:@available) if Libraries.instance_variable_defined?(:@available)
    end

    private

    def file(path)
      path = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')
      path
    end

    def link(path, target)
      path = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.symlink(target, path)
    end

    def with_otool(load_commands, &)
      otool = lambda do |paths|
        paths.map { |path| "#{path}:\n#{commands(**load_commands.fetch(path, {}))}" }.join
      end
      Libraries.stub(:available?, true) { Libraries.stub(:otool, otool, &) }
    end

    def commands(libraries: [], rpaths: [])
      lines = ["Load command 0\n      cmd LC_SEGMENT_64\n  cmdsize 72\n  segname __PAGEZERO\n",
               "Load command 1\n          cmd LC_ID_DYLIB\n      cmdsize 48\n         name /self.dylib (offset 24)\n"]
      libraries.each do |name|
        lines << "Load command 2\n          cmd LC_LOAD_DYLIB\n      cmdsize 56\n         name #{name} (offset 24)\n " \
                 "time stamp 2 Thu Jan  1 01:00:02 1970\n"
      end
      rpaths.each do |path|
        lines << "Load command 3\n          cmd LC_RPATH\n      cmdsize 32\n         path #{path} (offset 12)\n"
      end
      lines.join
    end
  end
end
