# frozen_string_literal: true

require_relative 'lib/mxc/version'

Gem::Specification.new do |spec|
  spec.name = 'mxc'
  spec.version = MXC::VERSION
  spec.authors = ['Carmine Paolino']
  spec.email = ['carmine@paolino.me']

  spec.summary = "Run untrusted commands in OS sandboxes from Ruby, through Microsoft's MXC."
  spec.description = "An unofficial Ruby binding to Microsoft's MXC. Run commands in Bubblewrap or Seatbelt " \
                     'sandboxes with filesystem, network, environment and timeout policies.'
  spec.homepage = 'https://crmne.github.io/mxc/'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/crmne/mxc'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/crmne/mxc/issues'
  spec.metadata['changelog_uri'] = 'https://github.com/crmne/mxc/releases'
  spec.metadata['funding_uri'] = 'https://github.com/sponsors/crmne'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir[
    'lib/**/*.rb',
    'ext/mxc/{Cargo.toml,build.rs,extconf.rb}',
    'ext/mxc/src/**/*.rs',
    'Cargo.toml',
    'Cargo.lock',
    'LICENSE',
    'NOTICE',
    'README.md'
  ]
  spec.require_paths = ['lib']
  spec.extensions = ['ext/mxc/extconf.rb']

  spec.add_dependency 'rb_sys', '~> 0.9.130'
end
