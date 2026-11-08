#!/usr/bin/env bash
# Build the RDoc API docs into the given directory, landing on the MXC module page.
#   docs/bin/build-api.sh <output-dir> [source-root]
# source-root is the checkout to document (default: this one), such as a
# release worktree that jekyll-vitepress build made.
set -euo pipefail

out="${1:?usage: build-api.sh <output-dir>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${2:-$repo}"
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

# Drop the docs bundle's env so the root Gemfile (which has rdoc) resolves.
unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_BIN BUNDLE_APP_CONFIG

# rdoc runs from this checkout's bundle but reads the source root's lib and
# .rdoc_options.
( cd "$source_root" && BUNDLE_GEMFILE="$repo/Gemfile" bundle exec rdoc --output "$out" --quiet lib )

# RDoc makes the landing page a meta-refresh to MXC.html; publish the module
# reference itself there so readers and crawlers get real content.
cp "$out/MXC.html" "$out/index.html"
