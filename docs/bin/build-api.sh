#!/usr/bin/env bash
# Build the RDoc API docs into the given directory, landing on the MXC module page.
#   docs/bin/build-api.sh <output-dir>
set -euo pipefail

out="${1:?usage: build-api.sh <output-dir>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

# Drop the docs bundle's env so the root Gemfile (which has rdoc) resolves.
unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_BIN BUNDLE_APP_CONFIG

( cd "$repo" && bundle exec rdoc --output "$out" --quiet lib )

# RDoc makes the landing page a meta-refresh to MXC.html; publish the module
# reference itself there so readers and crawlers get real content.
cp "$out/MXC.html" "$out/index.html"
