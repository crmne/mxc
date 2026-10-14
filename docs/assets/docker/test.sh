#!/usr/bin/env bash
# Reproduces the measurements on the Running in Docker page.
# Usage: docs/assets/docker/test.sh   (from anywhere; needs Docker and a
# compiled extension: run `bundle exec rake compile` first).
# CONTEXT overrides the build context (default: the repository root).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTEXT="${CONTEXT:-$(cd "$HERE/../../.." && pwd)}"
IMAGE="${IMAGE:-mxc-confine-test}"
PROFILE="$HERE/seccomp-bwrap.json"
HARDEN=(--cap-drop ALL --security-opt no-new-privileges --device /dev/net/tun)
CUSTOM=(--security-opt "seccomp=$PROFILE")
UNMASK=(--security-opt systempaths=unconfined)
PROBE=(ruby /app/docker/probe.rb)
OUTER=/app/docker/outer-sandbox.sh

docker build -q -f "$HERE/Dockerfile.test" -t "$IMAGE" "$CONTEXT" >/dev/null || exit 1

run() {
  local title=$1; shift
  local name="mxc-confine-test-$$-$RANDOM"
  echo "### $title"
  timeout 180 docker run --rm --name "$name" "$@"
  docker rm -f "$name" >/dev/null 2>&1
  echo
}

run "1. default Docker" "$IMAGE" "${PROBE[@]}" --quick
run "2. seccomp=unconfined only" --security-opt seccomp=unconfined "$IMAGE" "${PROBE[@]}" --quick
run "3. custom profile only" "${HARDEN[@]}" "${CUSTOM[@]}" "$IMAGE" "${PROBE[@]}" --quick
run "4. custom profile + systempaths=unconfined, plain bwrap (no wrapper)" \
  "${HARDEN[@]}" "${CUSTOM[@]}" "${UNMASK[@]}" -e PATH=/usr/sbin:/usr/bin:/usr/local/bin "$IMAGE" "${PROBE[@]}"
run "5. custom profile + systempaths=unconfined, wrapper loads the user namespace filter" \
  "${HARDEN[@]}" "${CUSTOM[@]}" "${UNMASK[@]}" "$IMAGE" "${PROBE[@]}"
run "6. custom profile, default systempaths, wrapper binds /proc + userns filter" \
  "${HARDEN[@]}" "${CUSTOM[@]}" -e MXC_BWRAP_PROC=bind "$IMAGE" "${PROBE[@]}"
run "7. nested: outer bwrap (fresh /proc), systempaths=unconfined" \
  "${HARDEN[@]}" "${CUSTOM[@]}" "${UNMASK[@]}" "$IMAGE" "$OUTER" "${PROBE[@]}"
run "8. nested: outer bwrap (bound /proc), default systempaths" \
  "${HARDEN[@]}" "${CUSTOM[@]}" -e MXC_BWRAP_PROC=bind "$IMAGE" "$OUTER" "${PROBE[@]}"

# Access checks only (test -w, head -c1); nothing is written to /proc.
CHECK='for f in sys/kernel/core_pattern sysrq-trigger; do test -w /proc/$f && printf "%s:WRITABLE " $f || printf "%s:no " $f; done; echo'
echo "### 9. container-level /proc writability (access check only)"
for user in root app; do
  for unmask in no yes; do
    extra=(); [ "$unmask" = yes ] && extra=("${UNMASK[@]}")
    printf 'user=%-4s systempaths=unconfined:%-3s ' "$user" "$unmask"
    docker run --rm -u "$user" --cap-drop ALL "${CUSTOM[@]}" "${extra[@]}" "$IMAGE" sh -c "$CHECK"
  done
done
