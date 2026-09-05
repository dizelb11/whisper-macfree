#!/usr/bin/env python3
"""Подсчёт ошибок по результатам прогона. Этап 0.

Две метрики:
  WER   — доля словных ошибок против expected.txt (что хотим видеть в тексте)
  Терм  — доля правильно распознанных доменных терминов из terms.txt

Терминная метрика важнее: общий WER размазывает ошибку по служебным словам,
а нас интересует, попал ли "Claude Code" вместо "клод код".
"""
import json
import re
from statistics import median
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).parent
RESULTS = HERE / "results"

PUNCT = "«»\"'`.,!?;:—–-()[]{}…"


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", text).lower().replace("ё", "е")
    text = text.replace(" ", " ")
    return re.sub(r"\s+", " ", text).strip()


def words(text: str) -> list[str]:
    return [w for w in (t.strip(PUNCT) for t in normalize(text).split()) if w]


def wer(ref: list[str], hyp: list[str]) -> tuple[int, int]:
    """Возвращает (число ошибок, длина эталона)."""
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[len(hyp)], len(ref)


def load_terms() -> dict[int, list[str]]:
    out: dict[int, list[str]] = {}
    src = HERE / "terms.txt"
    if not src.exists():
        src = HERE / "terms.sample.txt"
    for line in src.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        num, raw = line.split("\t", 1)
        out[int(num)] = [t.strip() for t in raw.split("|") if t.strip()]
    return out


def main() -> int:
    exp_file = HERE / "expected.txt"
    if not exp_file.exists():
        exp_file = HERE / "expected.sample.txt"
    expected = [ln.strip() for ln in exp_file.read_text(encoding="utf-8").splitlines() if ln.strip()]
    terms = load_terms()
    show_all = "--all" in sys.argv
    files = sorted(f for f in RESULTS.glob("*.json") if show_all or not f.stem.startswith("_"))
    if not files:
        print("Нет результатов в bench/results/ — сначала запусти transcribe.py")
        return 1

    rows = []
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        errs = length = hits = total = 0
        misses: list[str] = []
        for item in data["items"]:
            idx = int(Path(item["file"]).stem)
            if idx > len(expected):
                continue
            e, n = wer(words(expected[idx - 1]), words(item["text"]))
            errs += e
            length += n
            norm = normalize(item["text"])
            for term in terms.get(idx, []):
                total += 1
                if normalize(term) in norm:
                    hits += 1
                else:
                    misses.append(f"{idx:02d}:{term}")
        rows.append({
            "name": path.stem,
            "wer": errs / length if length else 0.0,
            "term": hits / total if total else 0.0,
            "hits": hits, "total": total,
            "sec": median(sorted(i["seconds"] for i in data["items"])),
            "misses": misses,
        })

    rows.sort(key=lambda r: (-r["term"], r["wer"]))
    width = max(len(r["name"]) for r in rows)
    print(f"\n{'модель':<{width}}  {'WER':>7}  {'термины':>16}  {"сек/фраза*":>11}")
    print("-" * (width + 40))
    for r in rows:
        print(f"{r['name']:<{width}}  {r['wer']:>6.1%}  {r['hits']:>4}/{r['total']:<3} {r['term']:>6.0%}  {r['sec']:>9.2f}")

    print("\nНе распознанные термины:")
    for r in rows:
        print(f"  {r['name']}: {', '.join(r['misses']) if r['misses'] else '— все на месте'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
