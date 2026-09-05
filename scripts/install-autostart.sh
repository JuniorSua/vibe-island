#!/bin/bash
# Makes Vibe Island start at login and come back if it ever dies.
#
# Without this the app simply stops existing after a reboot and the island
# shows nothing until you relaunch it by hand — which looks exactly like the
# app being broken.
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/app.vibeisland.clone.plist"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>app.vibeisland.clone</string>
    <key>ProgramArguments</key>
    <array><string>/Applications/VibeIsland.app/Contents/MacOS/VibeIsland</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>/tmp/vibeisland.err.log</string>
</dict>
</plist>
PLISTEOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "Installed. Vibe Island now starts at login and restarts itself if it dies."
echo "To undo:  launchctl unload -w \"$PLIST\" && rm \"$PLIST\""
