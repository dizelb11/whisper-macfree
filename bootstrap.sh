#!/bin/bash
# Установка одной командой:
#   curl -fsSL .../bootstrap.sh | bash
# Аргументы установщика передаются так:
#   curl -fsSL .../bootstrap.sh | bash -s -- --skip-autostart
#
# Клонирует проект в ~/whisper-macfree и запускает установщик.
set -uo pipefail

REPO="https://github.com/dizelb11/whisper-macfree.git"
DEST="${WHISPER_MACFREE_DIR:-$HOME/whisper-macfree}"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "Нужен Mac на Apple Silicon (M1 и новее)." >&2
    exit 1
fi

command -v git >/dev/null 2>&1 || { echo "Не найден git. Установите Command Line Tools: xcode-select --install" >&2; exit 1; }

if [ -d "$DEST/.git" ]; then
    echo "Проект уже есть в $DEST, обновляю..."
    git -C "$DEST" pull --ff-only || { echo "Не удалось обновить. Разберитесь в $DEST вручную." >&2; exit 1; }
elif [ -e "$DEST" ]; then
    echo "В $DEST уже что-то лежит, и это не наш репозиторий. Уберите или задайте другой путь:" >&2
    echo "  WHISPER_MACFREE_DIR=~/другая-папка ..." >&2
    exit 1
else
    echo "Клонирую в $DEST..."
    git clone -q "$REPO" "$DEST" || { echo "Не удалось склонировать." >&2; exit 1; }
fi

cd "$DEST" || exit 1
exec ./install.sh "$@"
