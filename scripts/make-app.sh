#!/bin/bash
# Builds a release binary and assembles VibeIsland.app in ./dist.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/VibeIsland.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/VibeIsland "$APP/Contents/MacOS/VibeIsland"
cp Assets/VibeIsland.icns "$APP/Contents/Resources/VibeIsland.icns"
# SwiftPM resource bundle (Codex pet spritesheet) — Bundle.module finds it
# inside Contents/Resources of the main bundle.
if [ -d .build/release/VibeIsland_VibeIsland.bundle ]; then
    cp -R .build/release/VibeIsland_VibeIsland.bundle "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VibeIsland</string>
    <key>CFBundleIdentifier</key><string>app.vibeisland.clone</string>
    <key>CFBundleName</key><string>Vibe Island</string>
    <key>CFBundleDisplayName</key><string>Vibe Island</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>VibeIsland</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Vibe Island jumps to the exact terminal tab running an agent session.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP"

rm -rf /Applications/VibeIsland.app
cp -R dist/VibeIsland.app /Applications/VibeIsland.app
echo "Installed /Applications/VibeIsland.app"
