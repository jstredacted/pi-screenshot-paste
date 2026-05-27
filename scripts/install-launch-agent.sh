#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
BIN="$BUILD_DIR/PiScreenshotPaste"
RESOURCE_BUNDLE="$BUILD_DIR/PiScreenshotPaste_PiScreenshotPaste.bundle"
APP="$HOME/Applications/PiScreenshotPaste.app"
APP_BIN="$APP/Contents/MacOS/PiScreenshotPaste"
APP_RESOURCES="$APP/Contents/Resources"
PLIST="$HOME/Library/LaunchAgents/com.justin.PiScreenshotPaste.plist"

echo "Building release binary..."
(cd "$ROOT" && mise exec -- swift build -c release)

mkdir -p "$APP/Contents/MacOS" "$APP_RESOURCES" "$HOME/Library/LaunchAgents"
cp "$BIN" "$APP_BIN"
chmod +x "$APP_BIN"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  rm -rf "$APP_RESOURCES/$(basename "$RESOURCE_BUNDLE")"
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
fi

if [[ -f "$ROOT/Sources/PiScreenshotPaste/Resources/PiPaste.icns" ]]; then
  cp "$ROOT/Sources/PiScreenshotPaste/Resources/PiPaste.icns" "$APP_RESOURCES/PiPaste.icns"
fi

if [[ -f "$ROOT/Sources/PiScreenshotPaste/Resources/MenuBarIcon.png" ]]; then
  cp "$ROOT/Sources/PiScreenshotPaste/Resources/MenuBarIcon.png" "$APP_RESOURCES/MenuBarIcon.png"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>PiScreenshotPaste</string>
  <key>CFBundleIdentifier</key>
  <string>com.justin.PiScreenshotPaste</string>
  <key>CFBundleName</key>
  <string>PiScreenshotPaste</string>
  <key>CFBundleDisplayName</key>
  <string>Pi Screenshot Paste</string>
  <key>CFBundleIconFile</key>
  <string>PiPaste</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.3</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Pi Screenshot Paste needs input monitoring to intercept Cmd+V in Ghostty when the clipboard contains a screenshot.</string>
</dict>
</plist>
PLIST

# Keep the bundle identity stable for macOS Privacy/TCC. A plain ad-hoc
# signature falls back to a cdhash designated requirement, which changes on
# every rebuild and makes macOS treat the helper as a new app for Accessibility
# and Input Monitoring. The explicit identifier requirement keeps rebuilds from
# rotating the privacy identity.
codesign --force --sign - \
  --requirements '=designated => identifier "com.justin.PiScreenshotPaste"' \
  "$APP" >/dev/null

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.justin.PiScreenshotPaste</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/PiScreenshotPaste.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/PiScreenshotPaste.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
pkill -x PiScreenshotPaste 2>/dev/null || true
sleep 0.5
launchctl load "$PLIST"
echo "Installed app bundle: $APP"
echo "Installed and loaded $PLIST"
echo "If Cmd+V interception does not work, grant Accessibility/Input Monitoring permissions to PiScreenshotPaste, then run:"
echo "  launchctl unload '$PLIST' && launchctl load '$PLIST'"
