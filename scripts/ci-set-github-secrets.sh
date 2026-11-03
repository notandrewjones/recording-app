#!/usr/bin/env bash
#
# One-time setup: stores the Apple credentials release.yml needs as GitHub secrets on this repo. Values go
# straight to GitHub. You need:
#   - The Developer ID Application identity exported from Keychain Access as a .p12, with its password.
#     Right-click the certificate in My Certificates, then Export.
#   - An App Store Connect API key .p8 with its Key ID and Issuer ID. ProductionDeck's key works, or make
#     one under Users and Access > Integrations > Keys.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v gh >/dev/null || { echo "gh not found. brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Setting secrets on: $REPO"

# Paths dragged into Terminal arrive quoted or with escaped spaces.
clean_path() {
  local p="$1"
  p="${p#\"}"; p="${p%\"}"
  p="${p#\'}"; p="${p%\'}"
  p="${p//\\ / }"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="${p/#\~/$HOME}"
  printf '%s' "$p"
}

read -r -p "Path to the Developer ID .p12: " P12_PATH
P12_PATH="$(clean_path "$P12_PATH")"
[[ -f "$P12_PATH" ]] || { echo "No such file: [$P12_PATH]" >&2; exit 1; }
read -r -s -p "Export password for that .p12: " P12_PW; echo

read -r -p "Path to the App Store Connect API key (.p8): " P8_PATH
P8_PATH="$(clean_path "$P8_PATH")"
[[ -f "$P8_PATH" ]] || { echo "No such file: [$P8_PATH]" >&2; exit 1; }
read -r -p "Key ID: " KEY_ID
read -r -p "Issuer ID: " ISSUER_ID
read -r -p "Apple Team ID: " TEAM_ID

base64 < "$P12_PATH"     | gh secret set -R "$REPO" MACOS_CERT_P12_BASE64
printf '%s' "$P12_PW"    | gh secret set -R "$REPO" MACOS_CERT_PASSWORD
base64 < "$P8_PATH"      | gh secret set -R "$REPO" NOTARY_KEY_P8_BASE64
printf '%s' "$KEY_ID"    | gh secret set -R "$REPO" NOTARY_KEY_ID
printf '%s' "$ISSUER_ID" | gh secret set -R "$REPO" NOTARY_ISSUER_ID
printf '%s' "$TEAM_ID"   | gh secret set -R "$REPO" APPLE_TEAM_ID

gh secret list -R "$REPO"
