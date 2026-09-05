#!/bin/bash
# Поднимает демон распознавания (если не поднят) и запускает Dictate.app.
set -uo pipefail
cd "$(dirname "$0")"

SOCK="$HOME/Library/Application Support/whisper-local/whisperd.sock"
LOG="$HOME/Library/Application Support/whisper-local/whisperd.log"

if pgrep -f "whisperd.py" >/dev/null; then
    echo "демон уже работает"
else
    echo "запускаю демон (первый старт грузит модель, ~15с)..."
    mkdir -p "$(dirname "$LOG")"
    nohup .venv/bin/python3 daemon/whisperd.py >>"$LOG" 2>&1 &
    for _ in $(seq 1 60); do
        [ -S "$SOCK" ] && break
        sleep 1
    done
    [ -S "$SOCK" ] && echo "демон готов" || { echo "демон не поднялся, смотри $LOG"; exit 1; }
fi

[ -d mac/Dictate.app ] || ./mac/bundle.sh
open mac/Dictate.app
echo "Dictate запущен — иконка 🎙 в менюбаре. Зажми Fn и говори."
