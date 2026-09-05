#!/usr/bin/env python3
"""Прогон через Parakeet TDT (другая архитектура, не Whisper). Этап 0.

Parakeet не принимает initial_prompt — подсказки-словаря у него нет.
Это и есть главный компромисс: он быстрее, но словарь к нему не прикрутить
тем же способом, только постобработкой.
"""
import argparse
import json
import re
import time
from pathlib import Path

from parakeet_mlx import from_pretrained

HERE = Path(__file__).parent
AUDIO = HERE / "audio"
RESULTS = HERE / "results"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("model", nargs="?", default="mlx-community/parakeet-tdt-0.6b-v3")
    args = ap.parse_args()

    wavs = sorted(AUDIO.glob("*.wav"))
    if not wavs:
        print("Нет записей в bench/audio/")
        return 1

    print(f"\nМодель: {args.model}\nФайлов: {len(wavs)}\n")
    model = from_pretrained(args.model)

    slug = re.sub(r"[^a-z0-9]+", "-", args.model.lower().split("/")[-1]).strip("-")
    RESULTS.mkdir(exist_ok=True)
    out = {"model": args.model, "prompt": False, "items": []}

    total = 0.0
    for wav in wavs:
        t0 = time.perf_counter()
        text = model.transcribe(str(wav)).text.strip()
        elapsed = time.perf_counter() - t0
        total += elapsed
        out["items"].append({"file": wav.name, "text": text, "seconds": round(elapsed, 2)})
        print(f"  {wav.name}  {elapsed:5.2f}s  {text}")

    out["total_seconds"] = round(total, 2)
    (RESULTS / f"{slug}.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nИтого {total:.1f}s ({total / len(wavs):.2f}s на фразу) → {slug}.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
