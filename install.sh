#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

label=io.github.nathanab.odyssey-g8-mac-fix
domain="gui/$(id -u)"
# Background agents can't read ~/Desktop, ~/Documents or ~/Downloads (macOS privacy protection), so the agent runs from here.
dest="$HOME/Library/Application Support/odyssey-g8-mac-fix"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/odyssey-g8-mac-fix.log"

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
swiftc -O -swift-version 5 -o "$build/odyssey-g8-mac-fix" odyssey-g8-mac-fix.swift

# Capture before the bootout, so a capture that refuses leaves a running agent alone, like a failed build does.
# The helper moves the first release's replacement-edid.bin into edids/ when it starts, so that file counts as saved.
if ! compgen -G "$dest/edids/*.bin" >/dev/null && [[ ! -f "$dest/replacement-edid.bin" ]]; then
  "$build/odyssey-g8-mac-fix" capture
fi

launchctl bootout "$domain/$label" 2>/dev/null || true
mkdir -p "$dest" "$(dirname "$plist")" "$(dirname "$log")"
cp "$build/odyssey-g8-mac-fix" "$dest/"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dest/odyssey-g8-mac-fix</string>
    <string>watch</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$domain" "$plist"
echo "Installed. The log is at $log"
if [[ ! -f "$dest/edids/7306.bin" ]]; then
  echo "To also save the 75Hz EDID for the safety net, turn Input Signal Plus off, wait for the picture, and run \"$dest/odyssey-g8-mac-fix\" capture"
fi
