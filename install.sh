#!/bin/bash
# Установка whisper-local с нуля. Запускать из каталога проекта: ./install.sh
set -uo pipefail
cd "$(dirname "$0")"

# --skip-autostart: поставить всё, но не прописывать запуск при входе.
# Нужен для проверки установщика на копии проекта, чтобы не перебить
# рабочие агенты путями на неё.
SKIP_AUTOSTART=0
[[ " $* " == *" --skip-autostart "* ]] && SKIP_AUTOSTART=1

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
die()  { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }
step() { printf "\n\033[1m%s\033[0m\n" "$1"; }

step "1. Проверка системы"

[ "$(uname -s)" = "Darwin" ] || die "Только macOS."

# MLX работает исключительно на Apple Silicon. На Intel-маке смысла идти
# дальше нет: модель просто не запустится.
[ "$(uname -m)" = "arm64" ] || die "Нужен Mac на Apple Silicon (M1 и новее). MLX на Intel не работает."
ok "Apple Silicon: $(sysctl -n machdep.cpu.brand_string)"

MACOS=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS" -ge 14 ] || die "Нужна macOS 14 или новее, у вас $(sw_vers -productVersion)."
ok "macOS $(sw_vers -productVersion)"

FREE=$(df -g / | tail -1 | awk '{print $4}')
[ "$FREE" -ge 8 ] || die "Нужно минимум 8 ГБ свободного места, доступно ${FREE} ГБ."
ok "свободно ${FREE} ГБ"

step "2. Инструменты сборки"

if ! xcode-select -p >/dev/null 2>&1; then
    warn "Command Line Tools не установлены — открываю установщик"
    xcode-select --install
    die "Дождитесь окончания установки и запустите ./install.sh снова."
fi
swift --version >/dev/null 2>&1 || die "Swift недоступен. Попробуйте: sudo xcode-select --reset"
ok "Xcode Command Line Tools"

if ! command -v brew >/dev/null 2>&1; then
    die "Нужен Homebrew. Установите с https://brew.sh и запустите ./install.sh снова."
fi
ok "Homebrew"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  устанавливаю ffmpeg..."
    brew install ffmpeg >/dev/null 2>&1 || die "Не удалось установить ffmpeg."
fi
ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')"

PY=$(command -v python3 || true)
[ -n "$PY" ] || die "Не найден python3."
PYV=$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
[ "$(printf '%s\n3.10\n' "$PYV" | sort -V | head -1)" = "3.10" ] \
    || die "Нужен Python 3.10+, найден $PYV."
ok "Python $PYV"

step "3. Окружение Python (~1 ГБ)"

if [ ! -d .venv ]; then
    "$PY" -m venv .venv || die "Не удалось создать venv."
fi
.venv/bin/pip install -q --upgrade pip
echo "  ставлю mlx-whisper (распознавание)..."
.venv/bin/pip install -q mlx-whisper || die "Не удалось установить mlx-whisper."
ok "mlx-whisper"

ANSWER=y
# В неинтерактивном запуске вопрос задать некому — ставим.
if [ -t 0 ]; then
    read -r -p "  Ставить mlx-lm для причёсывания текста? Ещё ~2,5 ГБ моделью. [Y/n] " ANSWER
fi
if [[ ! "${ANSWER:-y}" =~ ^[Nn] ]]; then
    .venv/bin/pip install -q mlx-lm && ok "mlx-lm" || warn "mlx-lm не установился — причёсывание будет недоступно"
else
    warn "пропущено: причёсывание по Shift работать не будет"
fi

step "4. Сборка приложения"
./mac/bundle.sh >/dev/null 2>&1 || die "Не удалось собрать приложение."
ok "Dictate.app"

step "5. Загрузка модели распознавания (1,5 ГБ, это долго)"
.venv/bin/python3 -c "
import mlx_whisper, sys, os
os.system('ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 0.5 -ar 16000 -ac 1 -y /tmp/wl-warmup.wav 2>/dev/null')
mlx_whisper.transcribe('/tmp/wl-warmup.wav', path_or_hf_repo='mlx-community/whisper-large-v3-turbo', language='ru')
" 2>&1 | grep -vE "^\s*$|it/s\]" | tail -2
ok "модель загружена"

step "6. Автозапуск"
if [ "$SKIP_AUTOSTART" = 1 ]; then
    warn "пропущено по --skip-autostart, запускать через ./run.sh"
else
./install-autostart.sh >/dev/null 2>&1 && ok "демон и приложение будут запускаться при входе" \
    || warn "не удалось настроить автозапуск, запускайте через ./run.sh"
fi

cat <<'FINAL'

────────────────────────────────────────────────────────────
Осталось два действия руками — их за вас не сделать.

1. Системные настройки → Клавиатура → «Нажатие 🌐» → «Ничего не делать».
   Иначе macOS перехватит Fn себе и до приложения она не дойдёт.

2. Приложение попросит Универсальный доступ и микрофон — разрешите.
   Иконка 🔐 в менюбаре означает, что разрешение ещё не выдано;
   после выдачи она сама сменится на 🎙 в течение пары секунд.

Потом: зажмите Fn, скажите что-нибудь, отпустите.

Настройки и история — в меню иконки 🎙.
Если что-то не так, причина здесь:
  ~/Library/Application Support/whisper-local/dictate.log
────────────────────────────────────────────────────────────
FINAL
