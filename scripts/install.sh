#!/bin/bash
#
# Builds menubar-usage in release mode, installs the binary to
# ~/.local/bin, and registers a LaunchAgent so it starts at login and
# relaunches if it ever quits. Re-run any time to update to the latest build.
#
# Usage:
#   ./scripts/install.sh           # build + install + start
#   ./scripts/install.sh uninstall # stop + remove the LaunchAgent + binary

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/menubar-usage"
LABEL="com.local.menubar-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

uninstall() {
    echo "Stopping and removing $LABEL ..."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    rm -f "$BIN_PATH"
    echo "Uninstalled. (Build artifacts in $REPO_DIR/.build are left intact.)"
}

if [[ "${1:-}" == "uninstall" ]]; then
    uninstall
    exit 0
fi

echo "Building release binary ..."
( cd "$REPO_DIR" && swift build -c release )

echo "Installing to $BIN_PATH ..."
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/.build/release/menubar-usage" "$BIN_PATH"

# Ad-hoc code-sign so the macOS Keychain can bind your "Always Allow" decision
# (for the Claude token) to a stable identity for this binary.
codesign --force --sign - "$BIN_PATH" 2>/dev/null || true

echo "Writing LaunchAgent $PLIST ..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

echo "Loading the agent ..."
UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
# Give launchd a moment to fully tear down the old service before re-bootstrapping,
# otherwise bootstrap can fail with "Input/output error" (label still registered).
sleep 1
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null \
    || launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "Done. menubar-usage is running and will start automatically at login."
echo "To remove it later: ./scripts/install.sh uninstall"
