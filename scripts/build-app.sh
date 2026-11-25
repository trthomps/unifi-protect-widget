#!/usr/bin/env bash
# Builds "Protect Cameras.app" into ./build. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Protect Cameras"
EXECUTABLE="ProtectCameras"
BUNDLE_ID="${BUNDLE_ID:-io.github.trthomps.protect-cameras}"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc; set to a Developer ID to sign properly

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXECUTABLE"

APP="build/$APP_NAME.app"
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

"$BIN" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Protect Cameras connects to your UniFi console on the local network to show camera snapshots and events.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null
echo "Built $APP"
