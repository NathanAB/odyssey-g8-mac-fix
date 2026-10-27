#!/bin/bash
set -euo pipefail

label=io.github.nathanab.odyssey-g8-mac-fix
dest="$HOME/Library/Application Support/odyssey-g8-mac-fix"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
# A failed reset must not stop the uninstall: after a macOS update removes the private function, there is nothing to undo.
if [[ -x "$dest/odyssey-g8-mac-fix" ]]; then
  "$dest/odyssey-g8-mac-fix" reset || echo "Reset failed. Unplugging the monitor and plugging it back in restores its own EDID."
fi
rm -rf "$dest"
echo "Uninstalled."
