---
title: Checking the Host
nav_order: 4
description: Find out whether a machine can start sandboxes and which features it supports, and fix it when it cannot.
---

After reading this guide, you will know:

* How to check whether a machine can start sandboxes.
* How to list backends and query capabilities.
* Which errors the gem raises and how to act on them.

## Can this machine start a sandbox?

```ruby
MXC.supported? # => true
```

`supported?` starts a real sandbox that runs `exit 0` and caches the answer for the life of the process, once per backend. Installing Bubblewrap is not enough on its own: a container's seccomp profile or an AppArmor rule can still stop it, and only starting one tells you for sure.

When the answer is `false`, `availability` explains:

```ruby
availability = MXC.availability
availability.supported?  # => false
availability.reason      # => "Bubblewrap could not start the sandbox: bwrap: Can't mount proc on /proc: Operation not permitted"
availability.remediation # => "bwrap cannot mount a fresh /proc because the container masks /proc paths. ..."
```

Probe again after changing the machine with `MXC.availability(refresh: true)`.

A sandbox can check its own policy too, including the tools its network setting needs:

```ruby
sandbox = MXC.sandbox.with_network(allow: ["pypi.org"])
sandbox.supported?               # => false
sandbox.availability.remediation # => "Install slirp4netns, iptables and util-linux ..."
```

A good place for this check is a boot-time health check or a job that fails fast, so a misconfigured server is noticed before the first user needs it:

```ruby
Rails.application.config.after_initialize do
  unless SkillSandbox.new.supported?
    Rails.logger.error("Sandboxes are unavailable: #{SkillSandbox.new.availability.reason}")
  end
end
```

## Backends

`MXC.backends` lists what MXC finds on the machine, as `MXC::Backend` objects:

```ruby
MXC.backends
# => [#<MXC::Backend name=:bubblewrap tier=nil capabilities=[:proxy_enforcement]>]

backend = MXC.backends.first
backend.name         # => :bubblewrap
backend.capabilities # => [:proxy_enforcement]
backend.warnings     # => [] or MXC's reasons for missing capabilities
```

On Windows, the backend is `:process_container`, and `tier` names the kind of container MXC uses on this machine: `"base-container"` where Windows provides one, or `"appcontainer-dacl"` otherwise.

```ruby
MXC.backends
# => [#<MXC::Backend name=:process_container tier="appcontainer-dacl" capabilities=[]>]
```

A listed backend is installed, which is not the same as usable. Use `supported?` for that.

## Capabilities

`MXC.supports?` answers one question per capability for the configured backend, and is `false` whenever `supported?` is:

```ruby
MXC.supports?(:network)          # any network access works
MXC.supports?(:network_policy)   # host allow-lists work
MXC.supports?(:memory_limit)     # with_limits(memory: ...) works
MXC.supports?(:proxy_enforcement)
```

* `:network` means `with_network(true)` works.
* `:network_policy` means `with_network(allow: [...])` works: the network tools are installed and MXC can confine a sandbox to a proxy. It is always `false` on Windows.
* `:cpu_time_limit`, `:memory_limit`, and `:process_limit` mean the matching [limit]({% link _guides/policies.md %}#limits-and-priority) works, and `:priority` that `with_priority` does.
* Any other Symbol is checked against the capabilities MXC reports for the backend, such as `:proxy_enforcement`.

## Errors

The gem raises two kinds of errors. Both take the message first and carry details as readers:

```ruby
begin
  sandbox.run("python3 build.py")
rescue MXC::UnsupportedError => e
  e.message     # what went wrong
  e.code        # => :backend_unavailable
  e.remediation # what to change on the machine
rescue MXC::Error => e
  e.code        # => :backend_error
  e.operation   # the step that failed, when MXC names it
  e.native_code # the operating system's error code, when there is one
end
```

`MXC::UnsupportedError` is a subclass of `MXC::Error` for problems with the machine rather than the command. You fix them once, on the server:

| Situation | Remediation |
| --- | --- |
| Bubblewrap is missing | Install the `bubblewrap` package. |
| User namespaces are blocked | Allow unprivileged user namespaces on the host, or give the container the [seccomp profile]({% link _guides/running-in-docker.md %}#a-custom-seccomp-profile). |
| A container masks `/proc` | See [Handling the masked /proc]({% link _guides/running-in-docker.md %}#handling-the-masked-proc). |
| Network tools are missing | Install `slirp4netns`, `iptables`, and util-linux. |
| `/dev/net/tun` is unusable | `modprobe tun` on a host, `--device /dev/net/tun` in Docker. |
| The backend does not exist here | Use `:auto`, or the backend for this operating system. |
| A host allow-list on Windows | Use `network: false`, or `network: true` for unrestricted access. |
| Denied paths on Windows without BaseContainer | Leave the paths out of `readable` and `writable` instead of denying them. |

A plain `MXC::Error` usually means the request itself is wrong, such as a working directory the sandbox cannot see. Invalid settings, like an unknown backend, a non-positive timeout, or a malformed allow-list entry, raise `ArgumentError`.

A command that runs and fails is not an error. It returns a `Result` whose `success?` is `false`.
