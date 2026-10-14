---
title: Policies
nav_order: 3
description: Control what a sandboxed command can read, write, and reach, which environment it gets, and how long it runs.
---

After reading this guide, you will know:

* What a sandbox can see by default, and how to grant and hide paths.
* How to give a command no network, any network, or a list of allowed hosts.
* What host allow-lists need from the machine, and where they stop protecting you.
* How to set the environment, working directory, timeout, and backend.
* How policies behave on Windows.

Every policy setting has three forms that mean the same thing: a keyword for `MXC.run` and `MXC::Sandbox.new`, a chainable `with_` setter, and a class macro for `MXC::Sandbox` subclasses.

```ruby
MXC.run("make", writable: "tmp/build")
MXC.sandbox.with_writable("tmp/build").run("make")

class BuildSandbox < MXC::Sandbox
  writable "tmp/build"
end
```

Setters return the sandbox, so they chain. Passing `nil` resets a setting to its default.

## Filesystem

A new sandbox sees the system's programs and libraries (`/usr`, `/etc`, and similar) read-only, and nothing else from your machine: no home directory, no project, no other users' files. On Linux it also gets an empty private `/tmp`. On macOS there is no writable temporary directory, so give the command a writable one and point `TMPDIR` at it with `env`.

Grant access with three settings. Each takes Strings or Pathnames, accepts several paths at once, and adds to what is already there:

```ruby
sandbox = MXC.sandbox
  .with_readable("app/skills", "vendor/python")
  .with_writable(Rails.root.join("tmp/skills"))
  .with_denied("app/skills/secrets")
```

* `readable` paths can be read but not changed.
* `writable` paths can be read and changed, and the changes reach your machine.
* `denied` paths are hidden, even when they sit inside a readable or writable path.

Relative paths are expanded from the current directory when the command runs. `with_readable(nil)` clears the list.

Anything else the command writes is either refused or thrown away when the sandbox exits.

## Network

A sandbox has no network unless you give it one. It gets its own empty network namespace, so connections, DNS lookups, and local sockets on your machine are all out of reach.

### Any destination

```ruby
MXC.run("curl -sS https://example.com", network: true)
```

The command can reach anything your machine can, including services on `localhost` and your private network. Use this only for trusted commands.

### Allowed hosts

Most untrusted code needs a few known hosts, such as a package index. List them:

```ruby
sandbox = MXC.sandbox.with_network(allow: ["pypi.org", "*.pythonhosted.org"])
result = sandbox.run("pip download --no-deps -d /tmp/wheels requests")
result.blocked # => ["telemetry.example.com:443"]
```

Each entry is one of:

| Entry | Matches |
| --- | --- |
| `"pypi.org"` | `pypi.org` on ports 80 and 443 |
| `"*.pythonhosted.org"` | Any subdomain of `pythonhosted.org` (not `pythonhosted.org` itself) on ports 80 and 443 |
| `"example.com:8443"` | `example.com` on port 8443 only |
| `"203.0.113.7"` | That IP address on ports 80 and 443 |

Requests to anything else are refused with HTTP 403 and listed in `Result#blocked` as `host:port`. A malformed entry raises `ArgumentError` before the command starts.

#### How it works

MXC on Linux cannot filter traffic by host name, so the gem does it. For each call it starts a small HTTP proxy on `127.0.0.1` that only connects to allowed hosts, and asks MXC to confine the sandbox so the proxy is the only thing it can reach. Inside the sandbox, `HTTP_PROXY` and `HTTPS_PROXY` point at the proxy. The proxy stops when the command finishes.

#### Requirements

On Linux, any network access, allowed hosts or `true`, needs:

* `slirp4netns`, which gives the sandbox a private network.
* `iptables` and `ip6tables`, which confine that network to the proxy.
* `nsenter` and `unshare` from util-linux.
* A usable `/dev/net/tun`. In Docker, pass `--device /dev/net/tun`.

The gem checks for these before starting anything and raises `MXC::UnsupportedError` naming what is missing, with install instructions in `remediation`. `MXC.supports?(:network_policy)` tells you ahead of time whether allow-lists work on this machine.

On macOS, Seatbelt confines the sandbox to the proxy's port without extra packages.

#### What it does not protect against

* **Programs that ignore proxy settings get nothing.** `curl`, `pip`, `npm`, `gem`, Python's `urllib` and `requests`, and most HTTP clients honor `HTTPS_PROXY`. Raw sockets, UDP, DNS lookups, and IPv6 fail inside the sandbox.
* **Names that resolve to private addresses are refused.** The proxy will not connect to loopback, private, link-local, or carrier-grade NAT addresses, even for an allowed name, so a public name cannot be pointed at your internal services. To allow a private service, list its IP address.
* **The proxy checks the requested host, not what travels inside the connection.** It connects to the address it resolved for an allowed name, so a forged TLS SNI or `Host` header cannot reach anything else. An allowed host can still serve anything its owner chooses.
* **An allowed name's owner decides where it points.** The proxy resolves names when it connects and uses the address it checked, so DNS rebinding cannot redirect a connection to a private address. The domain's owner can still point it at another public address.
* **Other processes on your machine can use the proxy while a command runs.** It listens on `127.0.0.1` without credentials and only grants what the allow-list grants.

## Environment

The command starts from a minimal environment, not your process's. Add variables with `env`. Keys and values are converted to Strings, and later calls add to earlier ones:

```ruby
sandbox.with_env("LANG" => "C.UTF-8", "PYTHONDONTWRITEBYTECODE" => "1")
```

Never pass secrets the command does not need. Anything in its environment, it can read and send wherever its network policy allows.
{: .warning }

## Working directory

`directory` sets where the command starts. The sandbox must be able to see it, so make it readable or writable too:

```ruby
MXC.sandbox.with_readable("app/skills").with_directory("app/skills").run("python3 build.py")
```

On Linux, a directory the sandbox cannot see raises `MXC::Error` with a remediation that says so. On macOS, the command starts there but cannot read anything in it.

## Timeout

`timeout` takes seconds as anything that responds to `to_f`. When it runs out, MXC stops the command and everything it started, and `Result#timed_out?` is true:

```ruby
MXC.sandbox.with_timeout(30)
MXC.sandbox.with_timeout(2.minutes)
```

Without a timeout, the command runs until it exits. Set a default for every sandbox with `MXC.configure`.

## Backend

`backend` picks the sandbox technology:

* `:auto`, the default, uses Bubblewrap on Linux, Seatbelt on macOS, and ProcessContainer on Windows.
* `:bubblewrap`, `:seatbelt`, and `:process_container` ask for one explicitly, and raise `MXC::UnsupportedError` where it does not exist.

```ruby
MXC.configure { |config| config.backend = :bubblewrap }
```

## Windows

The same settings work on Windows, enforced by Windows' own process containers. A few things differ.

### Filesystem on Windows

A new sandbox can read what Windows lets every app container read, such as `C:\Windows` and `C:\Program Files`, and nothing of your user profile or project. `readable`, `writable`, and `denied` grant and hide paths as on other platforms. Each command gets its own temporary folder, and `TEMP`, `TMP`, and `LOCALAPPDATA` point into it.

On Windows builds without BaseContainer, MXC enforces paths in an AppContainer by adding entries to the access control lists of the paths you grant, and removes them when the command finishes. Your process needs permission to change those lists, and a large tree takes longer to grant. If your process crashes during a run, the entries stay until you remove them.

The AppContainer does not enforce `denied` paths, so a sandbox with any raises `MXC::UnsupportedError` there instead of running without them. Leave those paths out of `readable` and `writable` instead. `MXC.supports?(:filesystem_denied_paths)` tells you whether this machine enforces them.

### Network on Windows

* `false`, the default, gives the command no network.
* `true` lets it reach the internet. It cannot reach `localhost` or your private network.
* `allow:` raises `MXC::UnsupportedError`. MXC can only confine a Windows sandbox to a proxy in your process by also accepting inbound connections to the sandbox, so the gem does not offer host allow-lists there. `MXC.supports?(:network_policy)` is `false`.

### Environment and working directory on Windows

Windows programs need a few system variables to start, so the environment keeps `SYSTEMROOT`, `WINDIR`, `SYSTEMDRIVE`, `COMSPEC`, `PATHEXT`, `PATH`, `LOCALAPPDATA`, `TEMP`, `TMP`, `PROCESSOR_ARCHITECTURE`, `NUMBER_OF_PROCESSORS`, and `OS` from your process. Your own variables replace them, ignoring case. Nothing else from your environment reaches the command.

Without a `directory`, the command starts in `%SystemRoot%`.

## Reading a policy back

Every setting has a reader named after it. `timeout` and `backend` fall back to the global configuration:

```ruby
sandbox = SkillSandbox.new
sandbox.readable # => ["app/skills"]
sandbox.network  # => { allow: ["pypi.org"] }
sandbox.timeout  # => 30
sandbox.backend  # => :auto
```
