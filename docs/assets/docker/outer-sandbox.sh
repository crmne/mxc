#!/bin/sh
# Runs a command (the job worker) inside an outer bubblewrap sandbox:
# read-only system and app code, writable /app/tmp, /app/log and
# /app/storage, private /tmp, network shared with the container.
# MXC sandboxes started from inside it nest one level deeper, so this
# sandbox must be able to create user namespaces: it calls /usr/bin/bwrap
# directly to skip the wrapper, which would block them. With MXC_BWRAP_PROC=bind
# it binds the container's /proc (writable, so the inner bwrap can write
# uid maps; Docker's masks stay) instead of mounting a new one, which is
# what lets the inner sandboxes do the same without systempaths=unconfined.
# bwrap reads /proc/<pid> of its own children, so a bound /proc only works
# when this sandbox keeps the container's pid namespace.
# Usage: outer-sandbox.sh bin/jobs
set -eu
APP_DIR="${APP_DIR:-/app}"
if [ "${MXC_BWRAP_PROC:-}" = bind ]; then
  PROC="--bind /proc /proc"
  PIDNS=
else
  PROC="--proc /proc"
  PIDNS=--unshare-pid
fi
exec /usr/bin/bwrap \
  --unshare-user $PIDNS --unshare-ipc --unshare-uts \
  --die-with-parent --new-session \
  --ro-bind /usr /usr --ro-bind /etc /etc \
  --symlink usr/bin /bin --symlink usr/sbin /sbin \
  --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
  --ro-bind "$APP_DIR" "$APP_DIR" \
  --bind "$APP_DIR/tmp" "$APP_DIR/tmp" \
  --bind "$APP_DIR/log" "$APP_DIR/log" \
  --bind "$APP_DIR/storage" "$APP_DIR/storage" \
  --dev /dev --dev-bind-try /dev/net/tun /dev/net/tun $PROC --tmpfs /tmp \
  --chdir "$APP_DIR" \
  -- "$@"
