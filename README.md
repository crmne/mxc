<div align="center">

# MXC for Ruby

<strong>Run untrusted commands in an OS sandbox, from Ruby</strong>

[Documentation](https://crmne.github.io/mxc/) · [Getting Started](https://crmne.github.io/mxc/getting-started/) · [Running in Docker](https://crmne.github.io/mxc/running-in-docker/)

[![Gem Version](https://badge.fury.io/rb/mxc.svg)](https://badge.fury.io/rb/mxc)
[![CI](https://github.com/crmne/mxc/actions/workflows/ci.yml/badge.svg)](https://github.com/crmne/mxc/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

Your app runs code it did not write: scripts a model generated, skills users uploaded, build steps from someone else. MXC for Ruby runs them in a sandbox that decides what they can read, write, and reach, and how long they get.

```ruby
result = MXC.run("python3 build.py", readable: "app/skills", writable: "tmp/out", timeout: 30)
result.stdout
result.success?
```

It is an unofficial Ruby binding to [Microsoft's MXC](https://github.com/microsoft/mxc), the MIT-licensed sandbox library. Not affiliated with or endorsed by Microsoft.

## Installation

```sh
bundle add mxc
```

Precompiled gems cover Linux (x86_64 and ARM64, glibc and musl) and macOS (Intel and Apple Silicon). On Linux, install Bubblewrap:

```sh
sudo apt-get install bubblewrap
```

Commands that use the network also need `slirp4netns`, `iptables`, util-linux, and `/dev/net/tun`. macOS needs nothing extra.

## Usage

Run a command. It sees the system's programs read-only, a private `/tmp`, and no network:

```ruby
MXC.run("python3 -c 'print(6 * 7)'").stdout # => "42\n"
```

Build a policy with chainable setters:

```ruby
sandbox = MXC.sandbox
  .with_readable("app/skills")
  .with_writable(Rails.root.join("tmp/skills"))
  .with_denied("app/skills/secrets")
  .with_network(allow: ["pypi.org", "*.pythonhosted.org"])
  .with_env("LANG" => "C.UTF-8")
  .with_directory("app/skills")
  .with_timeout(30)

result = sandbox.run("pip download --no-deps -d /tmp/wheels requests")
result.blocked # => hosts the allow-list refused
```

Stream output as it arrives:

```ruby
sandbox.run("python3 train.py") { |chunk| print chunk.content }
```

Drive an interactive process:

```ruby
process = sandbox.spawn("python3 -i -q")
process.write("print(6 * 7)\n")
process.close_write
process.each { |chunk| print chunk.content }
process.wait # => #<MXC::Result exit_code=0 timed_out=false backend=:bubblewrap>
```

Name a policy you use in several places:

```ruby
class SkillSandbox < MXC::Sandbox
  readable "app/skills"
  writable "tmp/skills"
  network false
  timeout 30
end

SkillSandbox.new.run("python3 app/skills/build.py")
```

Check the machine before you rely on it:

```ruby
MXC.supported?                 # starts a real sandbox once and caches the answer
MXC.availability.remediation   # what to change when it cannot
MXC.supports?(:network_policy) # host allow-lists work here
MXC.backends                   # => [#<MXC::Backend name=:bubblewrap ...>]
```

## Platforms

| Platform | Backend | 0.1.0 |
| --- | --- | --- |
| Linux | Bubblewrap | Supported and tested |
| macOS | Seatbelt | Supported, tested in CI |
| Windows | | Not available: MXC's Windows backends do not build with the MinGW toolchain Ruby uses |

Docker blocks the namespaces Bubblewrap needs by default. [Running in Docker](https://crmne.github.io/mxc/running-in-docker/) shows the smallest set of changes that makes it work, with a seccomp profile and a Kamal configuration for a job role.

## Documentation

* [Getting Started](https://crmne.github.io/mxc/getting-started/)
* [Running Commands](https://crmne.github.io/mxc/running-commands/)
* [Policies](https://crmne.github.io/mxc/policies/)
* [Checking the Host](https://crmne.github.io/mxc/checking-the-host/)
* [Running in Docker](https://crmne.github.io/mxc/running-in-docker/)

## Development

```sh
bin/setup                    # bundle install and compile the extension
bundle exec rake             # compile, tests, Rust unit tests, RuboCop
```

Tests that start sandboxes skip on machines that cannot. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. The native extension bundles Microsoft's MXC, also MIT; see [NOTICE](NOTICE).
