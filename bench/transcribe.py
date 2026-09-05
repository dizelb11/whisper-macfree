#!/usr/bin/env python3
"""Прогон записанных фраз через модель Whisper. Этап 0.

  python transcribe.py <model_repo> [--prompt]

--prompt подмешивает dictionary.txt в initial_prompt, чтобы проверить,
даёт ли подсказка измеримый прирост на доменных терминах.
"""
import argparse
import json
import re
import time
from pathlib import Path

import mlx_whisper

HERE = Path(__file__).parent
AUDIO = HERE / "audio"
RESULTS = HERE / "results"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("model", help="HF repo, напр. mlx-community/whisper-large-v3-turbo")
    ap.add_argument("--prompt", action="store_true", help="подмешать dictionary.txt")
    ap.add_argument("--language", default="ru")
    args = ap.parse_args()

    wavs = sorted(AUDIO.glob("*.wav"))
    if not wavs:
        print("Нет записей в bench/audio/ — сначала запусти record.py")
        return 1

    initial_prompt = None
    if args.prompt:
        initial_prompt = (HERE / "dictionary.txt").read_text(encoding="utf-8").strip()

    slug = re.sub(r"[^a-z0-9]+", "-", args.model.lower().split("/")[-1]).strip("-")
    if args.prompt:
        slug += "_prompt"

    RESULTS.mkdir(exist_ok=True)
    out = {"model": args.model, "prompt": bool(args.prompt), "items": []}

    print(f"\nМодель: {args.model}{'  + словарь' if args.prompt else ''}")
    print(f"Файлов: {len(wavs)}\n")

    total_time = 0.0
    for wav in wavs:
        t0 = time.perf_counter()
        res = mlx_whisper.transcribe(
            str(wav),
            path_or_hf_repo=args.model,
            language=args.language,
            initial_prompt=initial_prompt,
        )
        elapsed = time.perf_counter() - t0
        total_time += elapsed
        text = res["text"].strip()
        out["items"].append({"file": wav.name, "text": text, "seconds": round(elapsed, 2)})
        print(f"  {wav.name}  {elapsed:5.2f}s  {text}")

    out["total_seconds"] = round(total_time, 2)
    path = RESULTS / f"{slug}.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nИтого {total_time:.1f}s ({total_time / len(wavs):.2f}s на фразу) → {path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
