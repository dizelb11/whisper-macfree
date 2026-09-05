#!/bin/bash
# Первая волна замера: семейство Whisper через mlx-whisper.
set -u
cd "$(dirname "$0")/.."
PY=.venv/bin/python3
MODELS=(
  mlx-community/whisper-large-v3-turbo
  mlx-community/whisper-large-v3-turbo-q4
  mlx-community/whisper-large-v3-mlx
  mlx-community/whisper-medium-mlx
  mlx-community/whisper-small-mlx
)
for m in "${MODELS[@]}"; do
  for flag in "" "--prompt"; do
    echo "=========== $m $flag ==========="
    $PY bench/transcribe.py "$m" $flag 2>&1 | tail -30 || echo "!!! УПАЛО: $m $flag"
  done
done
echo "=========== ВОЛНА 1 ЗАВЕРШЕНА ==========="
