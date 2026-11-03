#!/usr/bin/env bash
#
# Builds a Release ISORecorder.app. With a team ID (scripts/signing.env or the environment) it exports a
# Developer ID build for scripts/notarize.sh. Without one it stops at an ad-hoc signed archive.
#
# The version comes from the latest v* tag and the build number from the commit count. Set VERSION or
# BUILD_NUMBER to override them.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -f scripts/signing.env ]]; then
  # shellcheck disable=SC1091
  source scripts/signing.env
fi

ISO_DEVELOPMENT_TEAM="${ISO_DEVELOPMENT_TEAM:-}"
if [[ -n "$ISO_DEVELOPMENT_TEAM" ]]; then
  ISO_SIGN_IDENTITY="${ISO_SIGN_IDENTITY:-Developer ID Application}"
else
  ISO_SIGN_IDENTITY="-"
fi

TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*')"
VERSION="${VERSION:-${TAG#v}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/ISORecorder.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found. brew install xcodegen" >&2; exit 1; }

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Archiving $VERSION ($BUILD_NUMBER)"
xcodebuild \
  -project ISORecorder.xcodeproj \
  -scheme ISORecorder \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  ISO_SIGN_IDENTITY="$ISO_SIGN_IDENTITY" \
  ISO_DEVELOPMENT_TEAM="$ISO_DEVELOPMENT_TEAM" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

if [[ -z "$ISO_DEVELOPMENT_TEAM" ]]; then
  echo "==> Ad-hoc archive at $ARCHIVE_PATH. Set ISO_DEVELOPMENT_TEAM to export a Developer ID build."
  exit 0
fi

echo "==> Exporting Developer ID app"
rm -rf "$EXPORT_DIR"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${ISO_DEVELOPMENT_TEAM}</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

APP="$EXPORT_DIR/ISORecorder.app"

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if [[ "$SIGNATURE" != *"TeamIdentifier=$ISO_DEVELOPMENT_TEAM"* || "$SIGNATURE" != *"runtime"* ]]; then
  echo "ERROR: $APP is not signed with team $ISO_DEVELOPMENT_TEAM and the hardened runtime." >&2
  exit 1
fi

# Without this the app still launches, but finds no DeckLink hardware.
if ! codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "disable-library-validation"; then
  echo "ERROR: $APP lacks the library validation entitlement, so it can't load DeckLinkAPI.framework." >&2
  exit 1
fi

echo "==> Exported $APP"
