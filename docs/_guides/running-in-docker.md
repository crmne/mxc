---
title: Running in Docker
nav_order: 5
description: Configure a Docker container, and a Kamal job role, so it can start MXC sandboxes with the smallest set of relaxed defaults.
---

MXC's Linux backend runs each command in a Bubblewrap (`bwrap`) sandbox. Bubblewrap creates an unprivileged user namespace, then pid, ipc, uts, mount and net namespaces inside it. Docker's defaults block this. A default container still runs sandboxes, on Landlock, but without network access and with the other differences [Policies]({% link _guides/policies.md %}#landlock) lists. To run them on Bubblewrap, a container needs a few targeted changes. This page shows the smallest set we measured, what each change exposes, and how to apply it to only the job worker of a Kamal deployment.

After reading this guide, you will know:

* What runs in a default Docker container, and why Bubblewrap does not.
* Which syscalls a custom seccomp profile has to allow, and why `seccomp=unconfined` is not needed.
* Two ways to deal with Docker's masked `/proc`, and what each one costs.
* How to keep untrusted code in an MXC sandbox from creating its own user namespaces.
* How to configure a Kamal `job` role, and what risks remain.
* How to bound the whole container's memory, CPU, and processes.

All results below were measured on Linux 7.2 (x86_64), Docker 29.7.2, the `ruby:4.0-slim` image (Debian 13.7, `bubblewrap` 0.12.0) and mxc-sdk 1.0.0 with the resource limits of [the fork the gem builds on](https://github.com/crmne/microsoft-mxc). AppArmor was not enabled on the test host. [`test.sh`]({{ '/assets/docker/test.sh' | relative_url }}) reproduces every result, using the probe in [`probe.rb`]({{ '/assets/docker/probe.rb' | relative_url }}) and the image in [`Dockerfile.test`]({{ '/assets/docker/Dockerfile.test' | relative_url }}). Run `bundle exec rake compile`, then `docs/assets/docker/test.sh` from a checkout of the gem.

## A default container runs on Landlock

Without any change, `:auto` runs on Landlock, with a warning in `Result#warnings` that says why Bubblewrap could not:

```
backend: :landlock
fs_policy: exit=0 out="wrote\nro-write-blocked" err="/bin/sh: 1: cannot create .../readable/hack: Permission denied"
python subprocess+multiprocessing: exit=1 err="... PermissionError: [Errno 13] Permission denied"
limits: cpu_time=1.0 limit=:cpu_time allocation_over_memory_limit=failed
```

The filesystem policy and the limits hold. Python's `multiprocessing` fails because Landlock gives the sandbox no private `/dev/shm`, and sandboxes have no network. The same happens with `seccomp=unconfined` alone, and with the custom profile below while `/proc` stays masked. If your commands need neither the network nor `/dev/shm`, and the [Landlock differences]({% link _guides/policies.md %}#landlock) are acceptable, you can stop here.

## Why Bubblewrap fails in a default container

Two separate Docker defaults stop Bubblewrap.

**Seccomp.** Docker's default profile allows `clone` only without namespace flags, and `unshare`, `mount`, `umount2`, `pivot_root` and `setns` only when the container has `CAP_SYS_ADMIN`. `clone3` returns `ENOSYS`.

```
bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.
```

**Masked /proc.** Docker hides parts of `/proc` by mounting `/dev/null` or a tmpfs over `/proc/kcore`, `/proc/keys`, `/proc/timer_list`, `/proc/scsi` and others, and bind-mounts `/proc/sys`, `/proc/sysrq-trigger`, `/proc/irq`, `/proc/bus` and others read-only. Inside a user namespace these over-mounts are locked. The kernel only lets a user namespace mount a new procfs when the existing one is fully visible (`mount_too_revealing` in `fs/namespace.c`), so the new mount fails:

```
bwrap: Can't mount proc on /proc: Operation not permitted
```

MXC 1.0 always passes `--proc /proc` (`bwrap_command.rs`, line 695) and has no option to change it. With `seccomp=unconfined` alone you get the second error; only adding `--security-opt systempaths=unconfined` removes it.

## A custom seccomp profile

You do not need `seccomp=unconfined`. Starting from Docker's own profile ([moby/profiles](https://github.com/moby/profiles) `seccomp/v0.2.3`, the version Docker 29.7.2 vendors), add one rule:

```json
{
  "names": ["clone", "unshare", "mount", "umount2", "pivot_root", "setns"],
  "action": "SCMP_ACT_ALLOW",
  "comment": "bubblewrap (MXC): user, pid, ipc, uts, net and mount namespaces without CAP_SYS_ADMIN"
}
```

That is the whole diff. The complete profile is [`seccomp-bwrap.json`]({{ '/assets/docker/seccomp-bwrap.json' | relative_url }}).

We found the set by allowing fourteen candidates, then removing one at a time:

| Removed | Result |
| --- | --- |
| `clone` | `bwrap: No permissions to create a new namespace` |
| `unshare` | `bwrap: unshare user ns: Operation not permitted` |
| `mount` | `bwrap: Failed to make / slave: Operation not permitted` |
| `umount2` | `bwrap: unmount old root: Operation not permitted` |
| `pivot_root` | `bwrap: pivot_root: Operation not permitted` |
| `setns` | Sandboxes without network work; sandboxes with network access fail with `bwrap exited before publishing child information` (MXC joins a prepared user namespace with `--userns FD`) |
| `clone3`, `mount_setattr`, `open_tree`, `move_mount`, `fsopen`, `fsmount`, `fsconfig`, `fspick` | No effect. Left out. |

`clone3` keeps Docker's `ENOSYS` answer; glibc and Python fall back to `clone`, and `subprocess` plus `multiprocessing` worked in every sandbox. The added syscalls give nothing to a process without a user namespace: `mount` and `pivot_root` still need `CAP_SYS_ADMIN`, which a container process only gets inside a namespace it created. What the rule really opens is user namespace creation, and with it the kernel code reachable from inside one.

Network access, whether `with_network(true)` or a host allow-list, also needs the TUN device for slirp4netns: `--device /dev/net/tun`. Without it MXC reports `open("/dev/net/tun"): No such file or directory`.

## Handling the masked /proc

There are two working setups. Both use the profile above, and in both, sandboxes with and without network access work, including host allow-lists.

### Option A: unmask /proc for the container

Add `--security-opt systempaths=unconfined`. Bubblewrap then mounts a fresh procfs for the sandbox's pid namespace, which is what MXC expects: the sandbox sees only its own 4 processes and `getpid()` matches `/proc/self`.

The cost is the whole container's `/proc`. We checked write access (with `test -w`, writing nothing) to the two classic escape files:

| Container user | Default | `systempaths=unconfined` |
| --- | --- | --- |
| root (even with `--cap-drop ALL`) | not writable | `/proc/sys/kernel/core_pattern` and `/proc/sysrq-trigger` **writable** |
| app (uid 1000) | not writable | not writable |

Root in a container without a user namespace remap is root on the host's sysctls. A writable `core_pattern` is a known path to code execution on the host. Use option A only if every process in the container runs as a non-root user and `no-new-privileges` stops setuid binaries from getting back to root.

### Option B: keep Docker's masks and bind /proc

Bubblewrap can bind the container's `/proc` instead of mounting a new one (`--ro-bind /proc /proc`). This needs no `systempaths` change, and Docker's masks stay in place inside the sandbox (`/proc/kcore` is still `/dev/null`, `/proc/keys` unreadable, `/proc/sys` read-only).

The cost:

* The sandbox lists the container's processes and can read their command lines (14 processes in our test, including the worker). It cannot read their environments (`/proc/<pid>/environ`: `Permission denied`) and cannot signal them, because they are outside its pid namespace.
* `/proc/self` points at the container-level pid, so it no longer matches `getpid()`. Programs that build `/proc/<getpid()>/...` paths read the wrong process. Python `subprocess` and `multiprocessing` worked.
* Dropping `--unshare-pid` as well makes the pid view consistent but lets sandboxed code `kill` the worker. We measured that, and do not recommend it.

MXC 1.0 cannot do this by itself. It runs `bwrap` through a `PATH` lookup (`Command::new("bwrap")` in `bwrap_runner.rs`), so a wrapper at `/usr/local/bin/bwrap` can rewrite MXC's `--proc /proc` before calling `/usr/bin/bwrap`. [`bwrap-wrapper.sh`]({{ '/assets/docker/bwrap-wrapper.sh' | relative_url }}) does this when `MXC_BWRAP_PROC=bind`. It depends on MXC 1.0's argument layout, so treat it as a workaround to retest on every MXC upgrade, not a stable interface.

## Stopping nested user namespaces

MXC 1.0 does not pass `--disable-userns` (no occurrence in the crate), and Docker's seccomp filter is inherited by everything in the container. With the custom profile, untrusted code inside an MXC sandbox can create its own user namespaces:

```
inner unshare -U:                 exit=0 out="USERNS-CREATED"
inner unshare -U, with network: exit=0 out="200 USERNS-CREATED"
inner unshare -Ur:                exit=0 out="0"
inner nested bwrap:               exit=0 out="NESTED-BWRAP-OK"
```

That hands the user namespace attack surface, the main risk of the relaxed profile, to the code you trust least.

Bubblewrap's `--disable-userns` blocks it for sandboxes without network (`unshare failed: No space left on device`), but it does not cover sandboxes with network access, which uses `--userns FD` instead of `--unshare-user`, and it needs a fresh procfs, so it fails under option B (`bwrap: cannot open /proc/sys/user/max_user_namespaces: Read-only file system`).

The wrapper therefore loads a small seccomp filter into every sandbox with `bwrap --add-seccomp-fd`. Bubblewrap applies it after its own setup, so only the sandboxed command and its children are filtered. It fails `clone` and `unshare` with `CLONE_NEWUSER` (`EPERM`) and `clone3` (`ENOSYS`, so libc falls back to `clone`). [`deny-userns-filter.py`]({{ '/assets/docker/deny-userns-filter.py' | relative_url }}) generates it at image build time for x86_64 and aarch64. With it, in both options and both network modes:

```
inner unshare -U:                 exit=1 err="unshare: unshare failed: Operation not permitted"
inner unshare -U, with network: exit=1 out="200" err="unshare: unshare failed: Operation not permitted"
inner nested bwrap:               bwrap: No permissions to create a new namespace
```

The worker itself can still create user namespaces. It has to, to start sandboxes.

## Running the worker in an outer sandbox

You can also start the worker itself inside a Bubblewrap sandbox, with read-only app code and only `tmp/`, `log/` and `storage/` writable, and let MXC nest its sandboxes inside. [`outer-sandbox.sh`]({{ '/assets/docker/outer-sandbox.sh' | relative_url }}) is a shell example. Both options work nested (all checks passed), with conditions:

* The outer sandbox must not use `--disable-userns` or the user namespace filter, and must call `/usr/bin/bwrap` directly so the wrapper does not add the filter to it.
* It needs `--dev-bind-try /dev/net/tun /dev/net/tun` for network access.
* Option A: the outer sandbox mounts a fresh `/proc` and may unshare its pid namespace.
* Option B: the outer sandbox must share the container's pid namespace and bind `/proc` writable (`--bind /proc /proc`). Bubblewrap reads `/proc/<child pid>` and writes the child's uid map there; with a pid namespace it failed with `open /proc/4/ns/ns failed`, and with a read-only bind with `setting up uid map: Read-only file system`. Docker's masks and read-only paths stay in force under the writable bind.

The outer sandbox does not shrink the kernel attack surface. The worker still needs user namespaces, and an attacker who controls the worker (for example through a tool call steered by prompt injection) can create them inside or outside the outer sandbox alike. What it adds is a read-only view of the app and system files for the worker process. In a container that runs as a non-root user without write access to the app directory, that is already the case. We do not think the extra moving part is worth it; the user namespace filter on the inner sandboxes is the change that matters.

## Recommended setup

Use option B with the wrapper, a non-root user, and the custom profile, on the job role only.

### Dockerfile

Save [`bwrap-wrapper.sh`]({{ '/assets/docker/bwrap-wrapper.sh' | relative_url }}), [`deny-userns-filter.py`]({{ '/assets/docker/deny-userns-filter.py' | relative_url }}) and [`seccomp-bwrap.json`]({{ '/assets/docker/seccomp-bwrap.json' | relative_url }}) in your app's `config/mxc/`, then add to the app's Dockerfile (Rails 8's generated Dockerfile already ends with `USER 1000:1000`):

```dockerfile
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y bubblewrap slirp4netns iptables util-linux python3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY --chmod=755 config/mxc/bwrap-wrapper.sh /usr/local/bin/bwrap
COPY config/mxc/deny-userns-filter.py /tmp/
RUN mkdir -p /usr/local/lib/mxc && \
    python3 -I /tmp/deny-userns-filter.py /usr/local/lib/mxc/deny-userns.bpf && \
    rm /tmp/deny-userns-filter.py
```

`slirp4netns`, `iptables` and `util-linux` are only needed for network access, whether `with_network(true)` or a host allow-list. `python3` builds the filter and is usually what the untrusted code runs anyway.

### docker run

```sh
docker run \
  --user 1000:1000 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --security-opt seccomp=/etc/docker/seccomp/mxc-bwrap.json \
  --device /dev/net/tun \
  -e MXC_BWRAP_PROC=bind \
  my-app bin/jobs
```

For option A, replace `-e MXC_BWRAP_PROC=bind` with `--security-opt systempaths=unconfined`, and make sure nothing in the container runs as root.

### Kamal

Kamal 2 turns role `options` into `docker run` flags, repeating the flag for each list entry. Only the `job` role gets them:

```yaml
servers:
  web:
    - 192.0.2.10
  job:
    hosts:
      - 192.0.2.10
    cmd: bin/jobs
    env:
      clear:
        MXC_BWRAP_PROC: bind
    options:
      security-opt:
        - seccomp=/etc/docker/seccomp/mxc-bwrap.json
        - no-new-privileges
      cap-drop: ALL
      device: /dev/net/tun
```

The seccomp profile must be a file on the server. The Docker CLI reads the path given to `seccomp=` and sends the file's contents with the request (`parseSecurityOpts` in docker/cli); it does not accept inline JSON, and Kamal runs the CLI on each server. If the file is missing, the container does not start (`opening seccomp profile (...) failed`), so a mistake fails loudly. Ship it with your server provisioning, or with a `.kamal/hooks/pre-deploy` hook:

```sh
#!/bin/sh
set -e
for host in $(echo "$KAMAL_HOSTS" | tr ',' ' '); do
  ssh "root@$host" mkdir -p /etc/docker/seccomp
  scp config/mxc/seccomp-bwrap.json "root@$host:/etc/docker/seccomp/mxc-bwrap.json"
done
```

Do not set the profile as the daemon default (`seccomp-profile` in `daemon.json`): that would relax every container on the host, including `web`.

### AppArmor

Not tested. The test host does not run AppArmor (`docker info` lists only `seccomp` and `cgroupns`). On Ubuntu and Debian hosts with AppArmor, Docker applies the `docker-default` profile, which denies `mount`, and Ubuntu 23.10 and later can also restrict unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns`). Expect to need `--security-opt apparmor=unconfined` for the job role or a custom AppArmor profile there, and run `test.sh` on the target host before relying on this page.

## Limiting the container

[Limits]({% link _guides/policies.md %}#limits-and-priority) bound each process in a sandbox, and work in every setup on this page that can start one: a 1 second CPU time limit stopped a busy loop, and a 256 MB memory limit failed a 512 MB allocation. Docker can bound the whole container, every sandbox and the worker together, and covers what per-process limits cannot. Give the job role its own budget so a burst of sandboxed work cannot take memory or CPU from `web`:

```sh
docker run --memory 4g --cpus 2 --pids-limit 512 ... my-app bin/jobs
```

* `--memory` caps the container's memory, counted by the kernel across every process. When it runs out, the kernel stops processes inside the container instead of anywhere else on the host.
* `--cpus` caps the CPU time per second the container may use, so sandboxes share those cores and nothing else.
* `--pids-limit` caps how many processes and threads the container may hold at once. It is the process limit Linux sandboxes lack: `processes` raises `MXC::UnsupportedError` on Linux, because `RLIMIT_NPROC` would count the worker's own threads.

In Kamal, add them to the job role's `options`:

```yaml
    options:
      memory: 4g
      cpus: 2
      pids-limit: 512
```

## Residual risks

* **User namespaces for the worker.** Any process in the job container that is not inside an MXC sandbox can create user namespaces and reach the kernel code behind them. Kernel bugs reachable this way are found regularly. The worker is trusted code but large, and LLM-driven tool calls widen what can steer it. Keep the host kernel patched.
* **Sandboxed code runs under Docker's profile plus the filter.** It cannot create user namespaces, has no capabilities (`CapEff: 0`, `NoNewPrivs: 1`), and gets no `/sys`. It can still reach every syscall Docker's default profile allows.
* **Process visibility (option B).** Sandboxed code can list container processes and read their command lines. Do not put secrets in command lines.
* **Unmasked /proc (option A).** A root process in the container can write host sysctls and `/proc/sysrq-trigger`. Option A is only as safe as your guarantee that nothing runs as root.
* **The wrapper is unofficial.** It rewrites MXC 1.0's arguments and must be retested with every MXC or Bubblewrap upgrade. `test.sh` checks both behaviors.
* **Shared kernel.** Containers and Bubblewrap share the host kernel. For hostile code where a kernel exploit is in scope, use a VM boundary (Firecracker, gVisor, or a dedicated worker host) instead.

## What MXC would need upstream

These would make the wrapper unnecessary:

* An option to block nested user namespaces in the sandbox, for every network mode (a seccomp filter via `--add-seccomp-fd`, or `--disable-userns` where it applies).
* An option to bind the parent's `/proc` read-only instead of mounting a new procfs, for containers that keep Docker's masks.
* An option for the `bwrap` executable path, so a deployment does not depend on `PATH` order.

## Files

* [`seccomp-bwrap.json`]({{ '/assets/docker/seccomp-bwrap.json' | relative_url }}): Docker's default profile plus the rule above.
* [`bwrap-wrapper.sh`]({{ '/assets/docker/bwrap-wrapper.sh' | relative_url }}): the `/usr/local/bin/bwrap` wrapper.
* [`deny-userns-filter.py`]({{ '/assets/docker/deny-userns-filter.py' | relative_url }}): generates the user namespace filter.
* [`outer-sandbox.sh`]({{ '/assets/docker/outer-sandbox.sh' | relative_url }}): the nested worker example.
* [`Dockerfile.test`]({{ '/assets/docker/Dockerfile.test' | relative_url }}), [`probe.rb`]({{ '/assets/docker/probe.rb' | relative_url }}), [`test.sh`]({{ '/assets/docker/test.sh' | relative_url }}): the test image, the checks run inside it, and the matrix that reproduces this page.
