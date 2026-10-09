#!/bin/bash
# Builds Release into ./build, replaces ~/Applications/Menu Bar Usage for Claude.app
# with it and relaunches the app. --build-only stops after the build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Menu Bar Usage for Claude.app"
LOG="build/deploy.log"
mkdir -p build

echo "Building Release…"
if ! xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
    -derivedDataPath build clean build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -20 || true
    echo "Build failed; the full log is in $LOG" >&2
    exit 1
fi
echo "Built build/Build/Products/Release/$APP"

if [[ "${1:-}" == "--build-only" ]]; then
    exit 0
fi

pkill -x "Menu Bar Usage for Claude" 2>/dev/null || true
sleep 1
rm -rf "$HOME/Applications/$APP"
cp -R "build/Build/Products/Release/$APP" "$HOME/Applications/"
open "$HOME/Applications/$APP"
echo "Installed and relaunched ~/Applications/$APP"
