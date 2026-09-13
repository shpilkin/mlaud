#!/bin/bash
# Сборка самодостаточного MLaud.app и MLaud.dmg без Xcode.
# В бандл вкладываются: перемещаемый CPython (python-build-standalone от uv),
# site-packages (mlx, gigaam-mlx, soundfile, soxr, …) и пакет mlaud_worker.
# .env НЕ вкладывается — Telegram-токен/chat_id и модель задаются в окне «Настройки».
set -euo pipefail

cd "$(dirname "$0")"
REPO=".."

APP_NAME="MLaud"
EXE_NAME="MLaudApp"
BUNDLE_ID="com.mlaud.app"
VERSION="0.14.0"

VENV="$REPO/poc/.venv"
SITE="$VENV/lib/python3.12/site-packages"
WORKER_PKG="$REPO/worker/mlaud_worker"

BUILD_DIR=".build/release"
STAGE="$(mktemp -d)/dmgroot"
APP="$STAGE/$APP_NAME.app"
RES="$APP/Contents/Resources"

# --- предусловия ---
[ -d "$SITE" ] || { echo "нет site-packages: $SITE (создай poc/.venv)"; exit 1; }
[ -d "$WORKER_PKG" ] || { echo "нет пакета worker: $WORKER_PKG"; exit 1; }
PY_REAL=$("$VENV/bin/python" -c "import sys,os; print(os.path.realpath(sys.base_prefix))")
[ -d "$PY_REAL" ] || { echo "не нашёл базовый интерпретатор: $PY_REAL"; exit 1; }

echo "==> swift build -c release"
swift build -c release

echo "==> каркас $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BUILD_DIR/$EXE_NAME" "$APP/Contents/MacOS/$EXE_NAME"

echo "==> вкладываю перемещаемый Python ($(du -sh "$PY_REAL" | cut -f1), deref)"
cp -RL "$PY_REAL" "$RES/python"

echo "==> вкладываю site-packages ($(du -sh "$SITE" | cut -f1))"
mkdir -p "$RES/site-packages"
# rsync с исключением мусора, который раздувает бандл
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '*.dist-info/RECORD' \
      "$SITE/" "$RES/site-packages/"

echo "==> вкладываю иконку приложения"
[ -f "AppIcon.icns" ] || { echo "нет AppIcon.icns рядом с build-dmg.sh"; exit 1; }
cp "AppIcon.icns" "$RES/AppIcon.icns"

echo "==> вкладываю пакет mlaud_worker (без .env)"
mkdir -p "$RES/worker"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$WORKER_PKG" "$RES/worker/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXE_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Микрофон нужен для диктовки по ⌃⌥D и звонков Суфлёра: речь превращается в текст локально, на этом компьютере.</string>
    <key>NSLocalNetworkUsageDescription</key><string>Локальная сеть нужна, чтобы принимать записи с твоего iPhone напрямую: файлы идут на этот компьютер, минуя интернет.</string>
</dict>
</plist>
PLIST

# Подпись всего бандла (включая вложенные python и dylib).
#
# Важно, ЧЕМ подписано. При ad-hoc система опознаёт программу по хешу файла, поэтому
# после каждой пересборки выданный «Универсальный доступ» перестаёт к ней относиться —
# галка в списке остаётся, а AXIsProcessTrusted() отвечает «нет». Со стабильным
# сертификатом признак становится «тот же идентификатор и тот же сертификат», и
# разрешение переживает пересборку. Сертификат локальный, самоподписанный, см.
# docs/feature-dictation.md.
SIGN_ID="${MLAUD_SIGN_ID:-MLaud Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "==> codesign «${SIGN_ID}» (--deep)"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "==> ad-hoc codesign (--deep) — стабильной подписи нет:"
    echo "    разрешения придётся выдавать заново после каждой сборки"
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign пропущен)"
fi
echo "==> признак опознания: $(codesign -d -r- "$APP" 2>&1 | grep '^designated' | cut -c1-100)"

echo "==> создание $APP_NAME.dmg"
rm -f "$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$APP_NAME.dmg" >/dev/null

echo "==> готово: $(pwd)/$APP_NAME.dmg"
du -sh "$APP_NAME.dmg"
rm -rf "$STAGE"
