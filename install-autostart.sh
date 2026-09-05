#!/bin/bash
# Автозапуск демона и приложения при входе в систему.
#
# Демон — с KeepAlive: если упадёт, поднимется сам. Держит модель в памяти
# (~1.7 ГБ) постоянно, это и есть цена ответа за полсекунды.
# Приложение — через `open`, чтобы запускалось как бандл и сохраняло
# личность для выданных разрешений.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$AGENTS"

cat > "$AGENTS/local.whisper.whisperd.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.whisper.whisperd</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ROOT/.venv/bin/python3</string>
        <string>$ROOT/daemon/whisperd.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- launchd не наследует пользовательский PATH, а mlx-whisper зовёт
             ffmpeg для чтения WAV. Без этого демон падает в цикле. -->
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Application Support/whisper-local/whisperd.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Application Support/whisper-local/whisperd.log</string>
</dict>
</plist>
PLIST

cat > "$AGENTS/local.whisper.dictate.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.whisper.dictate</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$ROOT/mac/Dictate.app</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

for label in local.whisper.whisperd local.whisper.dictate; do
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$AGENTS/$label.plist"
    echo "включён: $label"
done
echo
echo "Проверить:   launchctl list | grep local.whisper"
echo "Отключить:   ./uninstall-autostart.sh"
