#!/usr/bin/env bash
#
# Notarizes and staples build/export/ISORecorder.app, then packages, notarizes and staples build/ISORecorder.dmg.
# Run scripts/build_release.sh first.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -f scripts/signing.env ]]; then
  # shellcheck disable=SC1091
  source scripts/signing.env
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ISO_SIGN_IDENTITY="${ISO_SIGN_IDENTITY:-Developer ID Application}"
[[ -n "$NOTARY_PROFILE" ]] || { echo "NOTARY_PROFILE not set. See scripts/signing.env.example." >&2; exit 1; }

BUILD_DIR="$REPO_ROOT/build"
APP="$BUILD_DIR/export/ISORecorder.app"
DMG="$BUILD_DIR/ISORecorder.dmg"
ZIP="$BUILD_DIR/ISORecorder-notarize.zip"
[[ -d "$APP" ]] || { echo "Missing $APP. Run scripts/build_release.sh first." >&2; exit 1; }

# Sparkle's nested helpers (Autoupdate, Updater.app, XPC services) must carry the same Developer ID signature.
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing the app"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Building the .dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ISO Recorder" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# The order matters: sign, notarize, staple. The app's ticket does not cover the image, so without its own
# submission stapling the .dmg fails with "Record not found".
echo "==> Signing, notarizing and stapling the .dmg"
codesign --force --sign "$ISO_SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Done: $DMG"
