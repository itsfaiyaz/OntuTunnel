#!/bin/zsh
# Builds dist/OntuTunnel.app (release, ad-hoc signed).
#   ./scripts/build-app.sh            build
#   ./scripts/build-app.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION 2>/dev/null || echo 1.0.0)"
APP="dist/OntuTunnel.app"

# --universal: one app for Apple Silicon and Intel Macs (used for the DMG)
ARCHS=(--arch arm64)
[[ " $* " == *" --universal "* ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/OntuTunnel"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OntuTunnel"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OntuTunnel</string>
  <key>CFBundleDisplayName</key><string>OntuTunnel</string>
  <key>CFBundleIdentifier</key><string>com.ontu.ontutunnel</string>
  <key>CFBundleExecutable</key><string>OntuTunnel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Adimyra</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
  osascript -e 'quit app "OntuTunnel"' 2>/dev/null || true
  rm -rf /Applications/OntuTunnel.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/OntuTunnel.app"
fi
