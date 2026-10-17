#!/bin/zsh
# Builds dist/OntuTunnel-<version>.dmg: universal app (Apple Silicon + Intel),
# an Applications shortcut to drag onto, and a note on opening it the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/OntuTunnel.app/Contents/Info.plist)
DMG="dist/OntuTunnel-$VERSION.dmg"
STAGE=$(mktemp -d)

cp -R dist/OntuTunnel.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open.txt" <<'TXT'
OntuTunnel — install

1. Drag OntuTunnel onto the Applications folder.
2. Open Applications and double-click OntuTunnel.
3. First time only: macOS says it can't verify the developer (the app is
   not notarized by Apple). Click "Done", then open
   System Settings → Privacy & Security, scroll down and click
   "Open Anyway" next to OntuTunnel, then "Open".
   (Or in Terminal:  xattr -dr com.apple.quarantine /Applications/OntuTunnel.app )
4. In OntuTunnel: Connection → choose how to connect (your server over SSH,
   your static IP, or Cloudflare Tunnel) and follow the steps. Guide page
   explains each one.

Needs macOS 14 (Sonoma) or newer. Works on Apple Silicon and Intel Macs.
Browser dashboard: http://localhost:7777 while OntuTunnel is running.
TXT

rm -f "$DMG"
hdiutil create -volname "OntuTunnel" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign - "$DMG" 2>/dev/null || true
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
lipo -archs dist/OntuTunnel.app/Contents/MacOS/OntuTunnel
