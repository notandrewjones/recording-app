#!/usr/bin/env bash
#
# Adds build/ISORecorder.dmg to an appcast. Usage: make_appcast.sh <tag> <appcast.xml>
# The appcast file is created if missing and updated in place. The EdDSA private key is read from
# SPARKLE_ED_PRIVATE_KEY. Enclosures point at the tag's GitHub Release asset.

set -euo pipefail
TAG="$1"; APPCAST="$2"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-notandrewjones/recording-app}"
DMG="$REPO_ROOT/build/ISORecorder.dmg"
[[ -f "$DMG" ]] || { echo "Missing $DMG" >&2; exit 1; }
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || { echo "SPARKLE_ED_PRIVATE_KEY is not set. Run scripts/sparkle-setup-keys.sh." >&2; exit 1; }

BIN="$("$REPO_ROOT/scripts/sparkle-tools.sh")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$DMG" "$WORK/"
[[ -f "$APPCAST" ]] && cp "$APPCAST" "$WORK/appcast.xml"

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO/releases/tag/$TAG" \
  --maximum-deltas 0 \
  -o "$WORK/appcast.xml" \
  "$WORK"

cp "$WORK/appcast.xml" "$APPCAST"
echo "==> Updated $APPCAST for $TAG"
