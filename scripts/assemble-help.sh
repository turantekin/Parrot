#!/bin/bash
# Assemble the Apple Help Book inside an app bundle from docs/help — the same
# files GitHub Pages serves, so the help is written exactly once. Called by
# both the Makefile bundle step and scripts/release.sh, BEFORE codesign.
#
#   scripts/assemble-help.sh dist/Parrot.app
set -euo pipefail

APP="${1:?usage: scripts/assemble-help.sh <path/to/Parrot.app>}"
SRC="docs/help"
BOOK="$APP/Contents/Resources/Parrot.help"
LPROJ="$BOOK/Contents/Resources/en.lproj"

rm -rf "$BOOK"
mkdir -p "$LPROJ"
cp "$SRC"/*.html "$SRC"/help.css "$LPROJ/"
cp -R "$SRC/img" "$LPROJ/img"

# The book's own identity. HPDBookAccessPath is the landing page; the index
# file is what gives the Help menu's search field results from our pages.
cat > "$BOOK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>com.uygar.parrot.help</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Parrot Help</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>HPDBookAccessPath</key>
	<string>index.html</string>
	<key>HPDBookIndexPath</key>
	<string>Parrot.helpindex</string>
	<key>HPDBookCSIndexPath</key>
	<string>Parrot.cshelpindex</string>
	<key>HPDBookTitle</key>
	<string>Parrot Help</string>
	<key>HPDBookType</key>
	<string>3</string>
</dict>
</plist>
PLIST

# Build the search indexes Help Viewer queries. Two formats: the default
# typedstream .helpindex for older viewers, and the Core Spotlight index
# modern macOS actually uses — the legacy one can't even be dumped by
# today's hiutil, and anchor jumps (Settings → About) need anchors (-a)
# present in the CS index.
hiutil -Caf "$LPROJ/Parrot.helpindex" "$LPROJ"
hiutil -C -a -I corespotlight -f "$LPROJ/Parrot.cshelpindex" "$LPROJ"

# A built book is useless unless the app's Info.plist points at it: without
# these two keys Help Viewer says "Help isn't available for Parrot" and the
# Settings → About anchor jump opens the generic macOS help instead. They were
# lost once already (7be0c1d), so fail the build rather than ship silently.
for key in CFBundleHelpBookFolder CFBundleHelpBookName; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || {
    echo "assemble-help: $APP/Contents/Info.plist has no $key; the Help menu would say help isn't available" >&2
    exit 1
  }
done

echo "==> help book assembled ($(ls "$LPROJ"/*.html | wc -l | tr -d ' ') pages, indexed)"
