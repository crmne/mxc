#!/bin/bash
# Installed as /usr/local/bin/bwrap, ahead of /usr/bin/bwrap on PATH. MXC 1.0
# runs `bwrap` through a PATH lookup and has no option for either change.
#
# 1. Loads a seccomp filter (deny-userns-filter.py) into every sandbox, so
#    code inside an MXC sandbox cannot create further user namespaces. This
#    covers both of MXC's modes: --unshare-user (network :deny) and
#    --userns FD (network :allow through slirp4netns), where bwrap's own
#    --disable-userns does not apply.
# 2. With MXC_BWRAP_PROC=bind, replaces MXC's `--proc /proc` with a
#    read-only bind of the container's /proc. Docker's /proc masks then stay
#    in place and the container no longer needs systempaths=unconfined. The
#    sandbox sees the container's process list (not their environments) and
#    /proc/self no longer matches getpid(). MXC emits `--proc /proc` before
#    any caller-supplied argument, so the first exact pair is MXC's own.
# 3. Hands bwrap its options through a descriptor, so they are not in its
#    command line, which other processes can read. Those options include the
#    variables set with `env` and the policy's paths. bwrap only takes options
#    that way, so the command after `--` stays on its command line, as it does
#    on the command's own.
set -euo pipefail
REAL_BWRAP="${MXC_REAL_BWRAP:-/usr/bin/bwrap}"
USERNS_FILTER="${MXC_USERNS_FILTER:-/usr/local/lib/mxc/deny-userns.bpf}"

args=("$@")
sandbox=
for arg in "${args[@]}"; do
  case "$arg" in
    --unshare-user | --userns) sandbox=1 ;;
    --) break ;;
  esac
done

if [ "${MXC_BWRAP_PROC:-}" = bind ]; then
  for ((i = 0; i + 1 < ${#args[@]}; i++)); do
    if [ "${args[i]}" = --proc ] && [ "${args[i + 1]}" = /proc ]; then
      args[i]=--ro-bind
      args=("${args[@]:0:i+1}" /proc "${args[@]:i+1}")
      break
    fi
  done
fi

if [ -n "$sandbox" ]; then
  exec {filter_fd}<"$USERNS_FILTER"
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" = -- ] && break
  done
  exec {options_fd}< <(printf '%s\0' "${args[@]:0:i}")
  exec "$REAL_BWRAP" --add-seccomp-fd "$filter_fd" --args "$options_fd" "${args[@]:i}"
fi
exec "$REAL_BWRAP" "${args[@]}"
