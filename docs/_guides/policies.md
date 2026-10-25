---
title: Policies
nav_order: 3
description: Control what a sandboxed command can read, write, and reach, which environment it gets, how long it runs, and how much it can use.
---

After reading this guide, you will know:

* What a sandbox can see by default, and how to grant and hide paths.
* How to give a command no network, any network, or a list of allowed hosts.
* What host allow-lists need from the machine, and where they stop protecting you.
* How to set the environment, working directory, timeout, and backend.
* How to limit CPU time, memory, and processes, and lower a command's priority.
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

### Shared libraries on macOS

A program built against libraries outside the system, such as a Ruby that links Homebrew's GMP, would not start in a sandbox that cannot read them. On macOS, the sandbox reads the library files the command's program links, and those they link in turn. Only those files become readable: not their directories, and never the whole Homebrew prefix. The program is the first argument, or the first word of a command for the shell, found on the `PATH` you set with `env`.

A program can also open libraries while it runs, like the extensions Ruby and Python load on `require` and `import`. Name them with `libraries_of`, and the sandbox reads the libraries they link:

```ruby
extensions = Dir[File.join(RbConfig::CONFIG["archdir"], "**", "*.bundle")]

MXC.sandbox
  .with_readable(RbConfig::CONFIG["prefix"])
  .with_libraries_of(*extensions)
  .run(RbConfig.ruby, "-ryaml", "-e", "puts YAML.dump(ok: true)")
```

MXC lists the libraries with `otool` from the Command Line Tools. On a Mac without them, and on Linux and Windows, where the sandbox already reads the system's libraries, neither grants anything.

To grant no library at all, so the command reads only the system's and what `readable` lists, turn them off:

```ruby
MXC.sandbox.with_libraries(false)

class StrictSandbox < MXC::Sandbox
  libraries false
end
```

`inspect` shows `libraries=false` when they are off, and the `libraries_of` you named.

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

## Limits and priority

A timeout bounds how long a command runs. Limits bound how much it uses while it runs: a script that spins on the CPU or allocates without end stops at its limit instead of starving your app.

```ruby
sandbox = MXC.sandbox.with_limits(cpu_time: 2.minutes, memory: 2.gigabytes).with_priority(:low)

MXC.run("python3 build.py", limits: { cpu_time: 120, memory: 2 * 1024**3 }, priority: :low)

class SkillSandbox < MXC::Sandbox
  limits cpu_time: 2.minutes, memory: 2.gigabytes
  priority :low
end
```

* `cpu_time` is the CPU time each process the command starts may use, in seconds. It takes anything that responds to `to_f`, including `ActiveSupport::Duration`. A process that uses it up is stopped.
* `memory` is the memory each process may allocate, in bytes. It takes anything that responds to `to_i`, including `2.gigabytes`, and is rounded up to whole megabytes. An allocation beyond it fails, and the program decides what happens next: Python raises `MemoryError`, other programs exit with an error or crash.
* `processes` is how many processes the command may run at once. Starting another one fails.

`cpu_time` and `memory` apply to each process separately, so a command that starts four workers gets four CPU time budgets. Passing `nil` for a limit removes it, `with_limits(nil)` removes them all, and `limits` reads them back.

`priority` lowers the scheduling priority of the command and everything it starts, so your app stays responsive while it runs. `:normal` is the default, `:low` is nice 10 on Linux and macOS and below normal on Windows, and `:lowest` is nice 19, or idle on Windows.

After a run, `Result#cpu_time` says how much CPU time the command used and `Result#limit_exceeded` which limit stopped it, as described in [Running Commands]({% link _guides/running-commands.md %}#results).

### Limits on each platform

| Limit | Linux | macOS | Windows |
| --- | --- | --- | --- |
| `cpu_time` | Yes, whole seconds | Yes, whole seconds | Yes |
| `memory` | Yes | No | Yes |
| `processes` | No | No | Yes |
| `priority` | Yes | Yes | Yes |

A limit the platform cannot enforce raises `MXC::UnsupportedError` before the command starts, with a `remediation` that says what to do instead. `MXC.supports?(:cpu_time_limit)`, `:memory_limit`, `:process_limit`, and `:priority` answer ahead of time.

On Linux and macOS, MXC sets limits with rlimits on the process it starts, and every process the command starts inherits them. On Linux, `memory` limits the heap and private memory (`RLIMIT_DATA`) rather than the address space (`RLIMIT_AS`). Many programs reserve far more address space than they use: LibreOffice crashes converting a small presentation under a 2 GB address-space limit, but converts it under a 2 GB data limit, which still stops a script that allocates 3 GB. macOS refuses both kinds of memory limit, so there is none there.

macOS answers a CPU time limit with a signal a program can ignore, so MXC also stops any process in the sandbox that goes over it. On Linux, a sandbox with limits or a priority runs the command as the first process of its sandbox, so the command collects its own finished background processes and, like any first process, ignores signals sent from inside the sandbox that it has no handler for.

On Windows, MXC applies limits to the job object that holds the command and everything it starts. Windows counts CPU time in user mode only and checks it every few seconds, so a process can run a little past its limit before it stops.

### Counting processes on Linux and macOS

Neither platform can count the processes of one sandbox, so `processes` raises `MXC::UnsupportedError` there. The rlimit that sounds right, `RLIMIT_NPROC`, counts every process of the user, including your app's own. To bound processes, limit the container your app runs in, such as with Docker's `--pids-limit`, as [Running in Docker]({% link _guides/running-in-docker.md %}#limiting-the-container) describes.

## Backend

`backend` picks the sandbox technology:

* `:auto`, the default, uses Bubblewrap on Linux, Seatbelt on macOS, and ProcessContainer on Windows. On Linux, it uses Landlock where Bubblewrap cannot create its namespaces.
* `:bubblewrap`, `:landlock`, `:seatbelt`, and `:process_container` ask for one explicitly, and raise `MXC::UnsupportedError` where it cannot run. `:bubblewrap` never falls back.

```ruby
MXC.configure { |config| config.backend = :bubblewrap }
```

`Result#backend` names the backend that ran the command, and a run that fell back to Landlock says why in `Result#warnings`.

### Landlock

[Landlock](https://docs.kernel.org/userspace-api/landlock.html) confines a process without namespaces, privileges, or helper programs, so it works where Bubblewrap cannot: in a default Docker container, on Ubuntu 23.10 and later with AppArmor's restriction on, and on hosts with `user.max_user_namespaces` at 0. It needs Linux 6.2 or newer with Landlock enabled. `MXC.backends` lists it, with a warning for each protection this kernel's Landlock lacks.

The same policy is enforced differently, and some of it is refused rather than weakened:

* **No network.** Landlock cannot tell one address from another, so it could only allow the whole host network, including your machine's loopback and inbound connections. The gem does not offer that: `network: true` and `allow:` raise `MXC::UnsupportedError`, and `MXC.supports?(:network)` is `false` where sandboxes run on Landlock. Without network, the command cannot create network sockets at all.
* **Denied paths only outside grants.** Landlock grants whole directory trees and cannot take part of one back, so a `denied` path inside a `readable` or `writable` one raises `MXC::UnsupportedError`. Grant the paths beside it instead.
* **The host's filesystem layout.** The command sees the real `/tmp` and `/dev` rather than private ones, with access only to what the policy grants, plus a private `TMPDIR`. There is no private `/dev/shm`, so POSIX semaphores, and with them Python's `multiprocessing` locks, fail with `Permission denied`.
* **No metadata changes by name.** Landlock decides who may read, write, and run files, not who may change their metadata, so MXC refuses permission, owner, timestamp, and extended attribute changes by path, even in `writable` paths: `chmod +x build/tool`, `chown`, and `touch` of an existing file you may only read fail with `Operation not permitted`. Changes through a file the command opened still work, so `touch` of a file it may write or a new file works, and a program can set a file's mode when it creates it or with `fchmod`. A command can still see whether a path outside the policy exists.
* **A directory it cannot read** is still where the command starts, as on Seatbelt. Bubblewrap refuses to start there.

CPU time and memory limits and priorities work as on Bubblewrap. The command runs as a child of your process rather than in a PID namespace of its own, and MXC stops everything it leaves running when it exits or times out.

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
sandbox.limits   # => { cpu_time: 120, memory: 2147483648 }
sandbox.priority # => :low
```
