#!/bin/zsh
# Собирает пробу активации в бандл (LSUIElement=true) и запускает её через `open`,
# как запускалось бы настоящее приложение. Журнал — ~/ASR/spikes/shell/probe.log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/ASR/spikes/shell"
APP="$OUT/Probe.app"
CYCLES="${1:-20}"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/probe/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -target arm64-apple-macos15.0 -o "$APP/Contents/MacOS/Probe" "$HERE/probe/main.swift" -framework AppKit
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
rm -f "$OUT/probe.log"
open -W "$APP" --args "$CYCLES"
cat "$OUT/probe.log"
