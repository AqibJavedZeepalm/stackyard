#!/bin/bash
# Builds, signs, notarizes and staples the macOS DMG on this Mac, then attaches it
# to the GitHub release for the tag. No Apple secrets ever leave this Mac.
#
#   SIGN="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary tool/release-mac.sh 1.0.1
#
# SIGN: a "Developer ID Application" identity (name or SHA-1) in your keychain.
# NOTARY_PROFILE: saved once with `xcrun notarytool store-credentials <name>`.
# UPLOAD=0 builds and notarizes without touching GitHub.
set -euo pipefail

VERSION="${1:?usage: tool/release-mac.sh <version, e.g. 1.0.1>}"
: "${SIGN:?set SIGN to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
cd "$(dirname "$0")/.."

FLUTTER=(flutter)
command -v fvm >/dev/null && FLUTTER=(fvm flutter)
APP=build/macos/Build/Products/Release/Stackyard.app
DMG="dist/Stackyard-$VERSION.dmg"

echo "== Build $VERSION"
"${FLUTTER[@]}" build macos --release --build-name "$VERSION" --dart-define=APP_VERSION="$VERSION"

echo "== Sign"
codesign --force --deep --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements --sign "$SIGN" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "== DMG"
rm -rf dist/dmg "$DMG" && mkdir -p dist/dmg
cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname Stackyard -srcfolder dist/dmg -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/dmg
codesign --force --timestamp --sign "$SIGN" "$DMG"

echo "== Notarize (a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG"

if [[ "${UPLOAD:-1}" == 1 ]]; then
  echo "== Attach to release v$VERSION"
  gh release upload "v$VERSION" "$DMG" --clobber
fi
echo "Done: $DMG"
