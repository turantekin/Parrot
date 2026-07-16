#!/bin/bash
# Build, sign, notarize, and package Parrot for distribution outside the App Store.
#
# Usage:
#   scripts/release.sh 0.9.0                 # full run (needs notary credentials, see below)
#   SKIP_NOTARIZE=1 scripts/release.sh 0.9.0 # local dry run: build + sign + DMG, no Apple submission
#
# One-time setup (interactive, ~2 minutes):
#   1. Create an app-specific password at https://account.apple.com
#      (Sign-In & Security -> App-Specific Passwords).
#   2. Store it for notarytool (prompts for the password, never lands in shell history):
#        xcrun notarytool store-credentials parrot-notary \
#          --apple-id <your-apple-id-email> --team-id 5D8KQ6NJGF
#
# Why not xcodebuild: Xcode 26.5's explicit-modules build races on WhisperKit's
# transitive deps in worktrees (see docs/IMPROVEMENT-ROADMAP.md, Build notes).
# swift build is reliable, so we assemble the .app ourselves, the same way the
# manual install recipe always has — plus actool for the icon, which swift build
# can't compile.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.9.0>}"
IDENTITY="Developer ID Application: Uygar Turantekin (5D8KQ6NJGF)"
PROFILE="parrot-notary"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Parrot.app"
PLIST="$APP/Contents/Info.plist"
BUILD_NUM="$(date +%Y%m%d%H%M)" # CFBundleVersion must be unique per submission
cd "$ROOT"

notarize() { # notarize <file>
  local out
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$out"
  if ! echo "$out" | grep -q "status: Accepted"; then
    echo "!! Notarization not accepted. Full log:" >&2
    echo "   xcrun notarytool log \$(echo above for the submission id) --keychain-profile $PROFILE" >&2
    exit 1
  fi
}

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Parrot "$APP/Contents/MacOS/Parrot"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Info.plist is xcodegen-managed and still has $(VAR) placeholders that Xcode
# would normally substitute — substitute them here instead.
cp Parrot/Info.plist "$PLIST"
plutil -replace CFBundleExecutable        -string Parrot            "$PLIST"
plutil -replace CFBundleIdentifier        -string com.uygar.parrot  "$PLIST"
plutil -replace CFBundleName              -string Parrot            "$PLIST"
plutil -replace CFBundleDevelopmentRegion -string en                "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION"       "$PLIST"
plutil -replace CFBundleVersion           -string "$BUILD_NUM"      "$PLIST"
plutil -replace LSMinimumSystemVersion    -string "14.0"            "$PLIST"

# Resources: SwiftPM resource bundles + the UI fonts (ATSApplicationFontsPath ".")
cp -R .build/release/*.bundle "$APP/Contents/Resources/"
cp Parrot/Fonts/*.otf "$APP/Contents/Resources/"

echo "==> compiling app icon (actool)"
ACTOOL_PLIST="$(mktemp /tmp/parrot-actool-XXXXXX.plist)"
xcrun actool Parrot/Assets.xcassets \
  --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ACTOOL_PLIST" > /dev/null
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && plutil -replace CFBundleIconFile -string AppIcon "$PLIST"
rm -f "$ACTOOL_PLIST"

echo "==> codesigning (Developer ID, hardened runtime, secure timestamp)"
# The SwiftPM resource bundles are flat (no Info.plist) and contain no code, so
# they can't and needn't be signed standalone — the app signature seals them.
# If a dep ever gains a real nested binary, notarization will flag it here.
codesign --force --options runtime --timestamp \
  --entitlements Parrot/Parrot.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  echo "==> notarizing the app (usually 1-5 min)"
  ZIP="$DIST/Parrot-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

echo "==> building DMG"
DMG="$DIST/Parrot-$VERSION.dmg"
STAGE="$(mktemp -d /tmp/parrot-dmg-XXXXXX)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Parrot" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  echo "==> notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "==> Gatekeeper verdicts"
  spctl -a -vv "$APP"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
else
  echo "==> SKIP_NOTARIZE set: skipped Apple submission, stapling, and Gatekeeper check"
fi

echo
echo "Done: $DMG"
echo "Publish: gh release create v$VERSION \"$DMG\" --title \"Parrot $VERSION\" --generate-notes"
