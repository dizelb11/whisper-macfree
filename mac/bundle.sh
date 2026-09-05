#!/bin/bash
# Собирает Dictate.app из бинаря SwiftPM.
# Бандл нужен ради Info.plist: без NSMicrophoneUsageDescription macOS убивает
# процесс при запросе микрофона, а разрешения выдаются приложению, не файлу.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="Dictate.app"
# Сначала остановить, потом удалять: macOS сохраняет бандл работающего
# приложения, восстанавливая его рядом под номерным именем — так плодились
# копии Dictate 2.app, Dictate 3.app и далее по одной на пересборку.
# || true: на свежей машине убивать нечего, а set -e принял бы это за отказ
pkill -f "Dictate.app/Contents/MacOS/Dictate" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Dictate "$APP/Contents/MacOS/Dictate"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Dictate</string>
    <key>CFBundleIdentifier</key><string>local.whisper.dictate</string>
    <key>CFBundleName</key><string>Dictate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Для распознавания надиктованной речи. Звук обрабатывается локально и никуда не отправляется.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

# Подпись ad-hoc: без неё macOS отказывается держать выданные разрешения.
codesign --force --sign - "$APP" 2>/dev/null

echo "Готово: $(pwd)/$APP"
