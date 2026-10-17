---
title: Getting Started
nav_order: 1
description: Install MXC for Ruby, check that your machine can start sandboxes, and run your first command.
---

After reading this guide, you will know:

* How to install the gem and what each platform needs.
* How to check that your machine can start a sandbox.
* How to run a command with a policy.
* How to describe a reusable sandbox as a class.

## Installation

Add the gem with Bundler:

```sh
bundle add mxc
```

RubyGems picks a precompiled gem for Linux, macOS, and Windows, so you do not need a Rust toolchain. On other platforms the gem compiles from source, which needs a recent stable Rust toolchain.

### Linux

Install Bubblewrap:

```sh
sudo apt-get install bubblewrap   # Debian and Ubuntu
sudo dnf install bubblewrap       # Fedora
sudo pacman -S bubblewrap         # Arch
```

Bubblewrap needs unprivileged user namespaces. Most distributions allow them. Ubuntu 23.10 and later restrict them through AppArmor, and containers block them by default. Where they are blocked, sandboxes run on [Landlock]({% link _guides/policies.md %}#landlock) instead, on Linux 6.2 or newer, without network access. [Running in Docker]({% link _guides/running-in-docker.md %}) covers containers.

Commands that use the network need three more things: `slirp4netns`, `iptables`, and a usable `/dev/net/tun`. Sandboxes without network access do not.

```sh
sudo apt-get install slirp4netns iptables util-linux
```

### macOS

Nothing to install. MXC uses Seatbelt, which ships with macOS.

### Windows

Nothing to install beyond Ruby from [RubyInstaller](https://rubyinstaller.org). MXC uses Windows' own process containers: a BaseContainer on Windows builds that provide one, and an AppContainer everywhere else. MXC supports Windows 11 24H2 (build 26100) and later, and the gem's tests also pass on Windows Server 2025.

Commands on Windows run through `cmd.exe` rather than `sh`, and host allow-lists are not available. [Running Commands]({% link _guides/running-commands.md %}#windows) and [Policies]({% link _guides/policies.md %}#windows) cover the differences.

## Check the machine

Ask whether a sandbox can start:

```ruby
MXC.supported? # => true
```

The answer comes from starting a real sandbox once, so it is accurate even when Bubblewrap is installed but blocked. When it is `false`, `MXC.availability` says why and what to change:

```ruby
availability = MXC.availability
availability.reason      # => "Bubblewrap could not start the sandbox: bwrap: No permissions to create a new namespace..."
availability.remediation # => "Unprivileged user namespaces are blocked. ..."
```

## Run a command

`MXC.run` starts a sandbox, runs the command, and returns an `MXC::Result`:

```ruby
result = MXC.run("python3 -c 'print(6 * 7)'")
result.stdout    # => "42\n"
result.success?  # => true
```

By default the command sees the system's programs and libraries read-only, a private `/tmp` on Linux, and nothing of your home directory or project. It has no network. Grant more with keywords:

```ruby
result = MXC.run(
  "python3 build.py",
  readable: "app/skills",
  writable: "tmp/out",
  directory: "app/skills",
  timeout: 30
)
```

## Build a sandbox step by step

`MXC.sandbox` returns an `MXC::Sandbox`. Its setters chain, so you can build a policy once and run many commands with it:

```ruby
sandbox = MXC.sandbox
  .with_readable("app/skills")
  .with_writable(Rails.root.join("tmp/skills"))
  .with_network(allow: ["pypi.org", "*.pythonhosted.org"])
  .with_timeout(30)

sandbox.run("pip download --no-deps -d tmp/skills requests")
sandbox.run("python3 app/skills/build.py")
```

## Describe a sandbox as a class

When the same policy appears in several places, give it a name. Class macros mirror the setters:

```ruby
class SkillSandbox < MXC::Sandbox
  readable "app/skills"
  writable "tmp/skills"
  network false
  timeout 30
end

SkillSandbox.new.run("python3 app/skills/build.py")
```

Every instance starts from the class's settings, and you can still change one instance with the setters or keywords:

```ruby
SkillSandbox.new(timeout: 120).run("python3 app/skills/train.py")
```

Subclasses inherit their parent's settings and add to them.

## Configure defaults

Set defaults for every sandbox in an initializer:

```ruby
MXC.configure do |config|
  config.timeout = 60
  config.backend = :auto
end
```

A sandbox's own setting wins over the configuration.
