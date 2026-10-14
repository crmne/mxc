# frozen_string_literal: true

require 'mkmf'
require 'rb_sys/mkmf'

create_rust_makefile('mxc/mxc') do |r|
  if Gem.win_platform?
    # RubyInstaller builds Ruby with MinGW, so the extension must use Rust's GNU
    # target even when rustup's default host is MSVC.
    unless ENV.key?('CARGO_BUILD_TARGET') || ENV.key?('RUST_TARGET')
      r.target = RbConfig::CONFIG['host_cpu'] == 'aarch64' ? 'aarch64-pc-windows-gnullvm' : 'x86_64-pc-windows-gnu'
    end

    # mxc-sdk's build script compiles version resources for its own Windows
    # executables with rc.exe, which it finds only for MSVC targets. This gem
    # never builds those executables, so a resource compiler that does nothing
    # lets the extension build without the Windows SDK.
    unless ENV.key?('RC_PATH')
      stub = File.expand_path('rc-stub.cmd')
      File.write(stub, "@exit /b 0\r\n")
      r.env = { 'RC_PATH' => stub }
    end
  end
end
