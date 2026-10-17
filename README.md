<div align="center">

# MXC for Ruby

<strong>Run untrusted commands in an OS sandbox, from Ruby</strong>

[Documentation](https://crmne.github.io/mxc/) · [Getting Started](https://crmne.github.io/mxc/getting-started/) · [Running in Docker](https://crmne.github.io/mxc/running-in-docker/)

[![Gem Version](https://badge.fury.io/rb/mxc.svg)](https://badge.fury.io/rb/mxc)
[![CI](https://github.com/crmne/mxc/actions/workflows/ci.yml/badge.svg)](https://github.com/crmne/mxc/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

Your app runs code it did not write: scripts a model generated, skills users uploaded, build steps from someone else. MXC for Ruby runs them in a sandbox that decides what they can read, write, and reach, how long they get, and how much CPU and memory they can use.

```ruby
result = MXC.run("python3 build.py", readable: "app/skills", writable: "tmp/out", timeout: 30)
result.stdout
result.success?
```

It is an unofficial Ruby binding to [Microsoft's MXC](https://github.com/microsoft/mxc), the MIT-licensed sandbox library. Not affiliated with or endorsed by Microsoft. Resource limits and the Landlock backend come from [a fork of MXC](https://github.com/crmne/microsoft-mxc) until they are part of MXC itself ([resource limits](https://github.com/microsoft/mxc/issues/1498), [Landlock](https://github.com/microsoft/mxc/issues/1494)).

## Installation

```sh
bundle add mxc
```

Precompiled gems cover Linux (x86_64 and ARM64, glibc and musl), macOS (Intel and Apple Silicon), and Windows (x64 and ARM64). On Linux, install Bubblewrap:

```sh
sudo apt-get install bubblewrap
```

Where Bubblewrap cannot create its namespaces, as in a default Docker container or on Ubuntu with AppArmor's restriction, sandboxes run on Landlock instead (Linux 6.2 or newer), without network access.

Commands that use the network also need `slirp4netns`, `iptables`, util-linux, and `/dev/net/tun`. macOS and Windows need nothing extra.

## Usage

Run a command. It sees the system's programs read-only, nothing of your home directory or project, and no network:

```ruby
MXC.run("python3 -c 'print(6 * 7)'").stdout # => "42\n"
```

One String runs through the shell, like `Kernel#system`. Pass the program and its arguments separately when part of the command comes from users, so each one reaches the program unchanged:

```ruby
MXC.run("python3", "convert.py", params[:filename])
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

Limit what a command can use, and lower its priority so your app stays responsive:

```ruby
result = sandbox.with_limits(cpu_time: 2.minutes, memory: 2.gigabytes).with_priority(:low).run("python3 build.py")
result.cpu_time       # => 3.42
result.limit_exceeded # => nil, or :cpu_time when it ran out
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
  limits cpu_time: 60, memory: 1.gigabyte
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

| Platform | Backend | 0.3.0 |
| --- | --- | --- |
| Linux | Bubblewrap | Supported and tested, without process limits |
| Linux 6.2 and later | Landlock, where Bubblewrap cannot run or when asked for | Supported and tested, without network access or process limits |
| macOS | Seatbelt | Supported and tested, without memory or process limits |
| Windows 11 24H2 and later | ProcessContainer | Supported and tested, without host allow-lists |

On Windows, a single String runs through `cmd.exe` instead of `sh`. See [Running Commands](https://crmne.github.io/mxc/running-commands/#windows) and [Policies](https://crmne.github.io/mxc/policies/#windows) for what else differs.

Docker blocks the namespaces Bubblewrap needs by default, so a default container runs sandboxes on Landlock. [Running in Docker](https://crmne.github.io/mxc/running-in-docker/) shows what that gives up, and the smallest set of changes that makes Bubblewrap work, with a seccomp profile and a Kamal configuration for a job role.

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
