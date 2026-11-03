#!/usr/bin/env bash
# Downloads Sparkle's command-line tools (generate_keys, sign_update, generate_appcast) into build/sparkle and
# prints their bin directory. The version matches the Sparkle package the app links.
set -euo pipefail
SPARKLE_VERSION="${SPARKLE_VERSION:-2.10.1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/build/sparkle-$SPARKLE_VERSION"
if [[ ! -x "$DEST/bin/sign_update" ]]; then
  mkdir -p "$DEST"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$DEST" >&2
fi
echo "$DEST/bin"
