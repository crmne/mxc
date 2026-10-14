# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'
require 'rb_sys/extensiontask'
require 'rubocop/rake_task'

CROSS_PLATFORMS = %w[
  x86_64-linux
  x86_64-linux-musl
  aarch64-linux
  aarch64-linux-musl
  x86_64-darwin
  arm64-darwin
].freeze

GEMSPEC = Gem::Specification.load('mxc.gemspec')

RbSys::ExtensionTask.new('mxc', GEMSPEC) do |ext|
  ext.lib_dir = 'lib/mxc'
  ext.cross_compile = true
  ext.cross_platform = CROSS_PLATFORMS
end

Minitest::TestTask.create(:test) do |t|
  t.test_globs = ['test/**/*_test.rb']
end

RuboCop::RakeTask.new

desc "Run the egress proxy's Rust unit tests"
task 'test:proxy' do
  mkdir_p 'tmp'
  sh 'rustc', '--edition', '2021', '--test', 'ext/mxc/src/proxy.rs', '-o', 'tmp/proxy_test'
  sh 'tmp/proxy_test'
end

namespace :release do
  desc 'Check that the release notes for the current version are committed'
  task :verify_notes do
    notes = "packaging/release-notes/v#{GEMSPEC.version}.md"
    abort "#{notes} is missing" unless File.file?(notes) && !File.empty?(notes)
    sh 'git', 'ls-files', '--error-unmatch', notes
    sh 'git', 'diff', '--exit-code', 'HEAD', '--', notes
  end
end

task default: %i[compile test test:proxy rubocop]
