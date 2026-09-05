#!/bin/bash
# Выключает автозапуск. Сами файлы проекта не трогает.
set -uo pipefail
for label in local.whisper.whisperd local.whisper.dictate; do
    launchctl bootout "gui/$UID/$label" 2>/dev/null && echo "выключен: $label" || echo "не был включён: $label"
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
