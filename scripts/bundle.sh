#!/bin/bash
# Builds TerminalHandler.app (with th-hook inside), signs it and installs it
# into ~/Applications. Usage: scripts/bundle.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TerminalHandler
swift build -c release --product th-hook
BIN="$(swift build -c release --show-bin-path)"

APP="build/TerminalHandler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TerminalHandler" "$APP/Contents/MacOS/TerminalHandler"
cp "$BIN/th-hook" "$APP/Contents/MacOS/th-hook"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>fi.slemppa.TerminalHandler</string>
    <key>CFBundleName</key><string>Terminal Handler</string>
    <key>CFBundleDisplayName</key><string>Terminal Handler</string>
    <key>CFBundleExecutable</key><string>TerminalHandler</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Terminal Handler lukee Ghosttyn terminaalit ja siirtää sinut oikeaan välilehteen.</string>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')"
IDENTITY="${IDENTITY:--}"
codesign --force --options runtime --entitlements /dev/stdin --sign "$IDENTITY" "$APP/Contents/MacOS/th-hook" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
ENT
codesign --force --options runtime --sign "$IDENTITY" \
  --entitlements /dev/stdin "$APP" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
ENT
echo "Signed with: $IDENTITY"

if [[ "${1:-}" != "--no-install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x TerminalHandler 2>/dev/null || true
  rm -rf "$HOME/Applications/TerminalHandler.app"
  cp -R "$APP" "$HOME/Applications/TerminalHandler.app"
  echo "Installed to ~/Applications/TerminalHandler.app"
fi
