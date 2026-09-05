#!/usr/bin/env python3
"""Диктофон для эталонного набора фраз (этап 0).

Показывает фразу, пишет её в 16 кГц моно WAV — родной формат Whisper.
Enter — начать запись, Enter — остановить. Прогресс сохраняется:
скрипт можно прервать и запустить снова, уже записанные фразы пропустятся.
"""
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
AUDIO = HERE / "audio"
DEVICE = ":0"  # аудиоустройство avfoundation (0 = Микрофон MacBook Pro)


def record(path: Path) -> None:
    proc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "avfoundation", "-i", DEVICE,
         "-ar", "16000", "-ac", "1", str(path)],
        stdin=subprocess.PIPE,
    )
    try:
        input("    ● запись... Enter — стоп ")
    finally:
        try:
            proc.communicate(b"q", timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def main() -> int:
    # Личный корпус в git не попадает: это голос и лексика владельца.
    # Без него берём образец из комплекта.
    source = HERE / "phrases.txt"
    if not source.exists():
        source = HERE / "phrases.sample.txt"
        print(f"(личного корпуса нет, беру образец {source.name})")
    phrases = [ln.strip() for ln in source.read_text(encoding="utf-8").splitlines() if ln.strip()]
    AUDIO.mkdir(exist_ok=True)

    print(f"\n{len(phrases)} фраз. Говори естественно, как обычно диктуешь — не дикторским голосом.")
    print("Enter — начать запись, Enter — остановить. 'r' — перезаписать, 's' — пропустить, 'q' — выйти.\n")

    for i, phrase in enumerate(phrases, 1):
        wav = AUDIO / f"{i:02d}.wav"
        while True:
            done = " ✓" if wav.exists() else ""
            print(f"[{i:2d}/{len(phrases)}]{done}  {phrase}")
            action = input("    Enter — писать, s — пропустить, q — выход: ").strip().lower()
            if action == "q":
                print("\nПрервано. Запусти снова — продолжит с этого места.")
                return 0
            if action == "s":
                break
            record(wav)
            size = wav.stat().st_size if wav.exists() else 0
            if size < 4000:
                print("    ⚠ файл подозрительно короткий — проверь доступ к микрофону, пишем заново\n")
                continue
            again = input("    Enter — дальше, r — перезаписать: ").strip().lower()
            if again != "r":
                print()
                break
            print()

    recorded = sorted(AUDIO.glob("*.wav"))
    print(f"\nГотово: {len(recorded)} из {len(phrases)} записано в bench/audio/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
