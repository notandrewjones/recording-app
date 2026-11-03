#!/usr/bin/env bash
#
# One-time setup for Sparkle updates. Creates the EdDSA signing key in your login Keychain (or reuses the one
# already there), stores the private key as the SPARKLE_ED_PRIVATE_KEY GitHub secret, and writes the public
# key into Config/App.xcconfig. Back up the key: without it, installed copies cannot accept new updates.
#   Export a backup:  "$(scripts/sparkle-tools.sh)/generate_keys" -x sparkle-private-key.txt

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v gh >/dev/null || { echo "gh not found. brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }

BIN="$(scripts/sparkle-tools.sh)"
"$BIN/generate_keys" >/dev/null   # creates the key on first run, otherwise keeps the existing one
PUBLIC_KEY="$("$BIN/generate_keys" -p)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$BIN/generate_keys" -x "$TMP/key"
gh secret set SPARKLE_ED_PRIVATE_KEY < "$TMP/key"

sed -i '' "s|^SPARKLE_PUBLIC_KEY =.*|SPARKLE_PUBLIC_KEY = $PUBLIC_KEY|" Config/App.xcconfig
echo "Public key: $PUBLIC_KEY (written to Config/App.xcconfig; commit it)"
echo "Private key stored as the SPARKLE_ED_PRIVATE_KEY secret on $(gh repo view --json nameWithOwner -q .nameWithOwner)."
