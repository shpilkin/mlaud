#!/bin/zsh
# Собирает пробу S2 в бандл и подписывает сертификатом «MLaud Local Signing» — тем же,
# что build-dmg.sh: разрешения TCC привязаны к подписи, ad-hoc менялась бы на каждой сборке.
# Аргумент — номер сборки: попадает в CFBundleVersion и в бинарь, чтобы пересборка была
# настоящей. Бандл: ~/ASR/spikes/appaudio/AppAudioProbe.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${APPAUDIO_OUT:-$HOME/ASR/spikes/appaudio}"
APP="$OUT/AppAudioProbe.app"
BUILD="${1:-1}"
STAMP_DIR="$(mktemp -d)"
trap 'rm -rf "$STAMP_DIR"' EXIT
mkdir -p "$APP/Contents/MacOS"
sed "s/BUILD_NUMBER/$BUILD/" "$HERE/probe/Info.plist" > "$APP/Contents/Info.plist"
printf 'let buildStamp = "build-%s-%s"\n' "$BUILD" "$(date +%H%M%S)" > "$STAMP_DIR/BuildStamp.swift"
swiftc -O -target arm64-apple-macos15.0 -swift-version 5 \
    -o "$APP/Contents/MacOS/Probe" "$HERE"/probe/*.swift "$STAMP_DIR/BuildStamp.swift" \
    -framework AppKit -framework CoreAudio -framework ScreenCaptureKit -framework AVFoundation
SIGN_ID="${MLAUD_SIGN_ID:-MLaud Local Signing}"
if ! security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
    echo "нет сертификата «$SIGN_ID» — разрешение не переживёт пересборку" >&2
    exit 1
fi
codesign --force --deep --sign "$SIGN_ID" "$APP"
echo "собрано: $APP (сборка $BUILD)"
codesign -d -r- "$APP" 2>&1 | grep '^designated' | cut -c1-120
