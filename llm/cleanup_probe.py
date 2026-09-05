#!/usr/bin/env python3
"""Проба локальной LLM для причёсывания расшифровки. Этап 4.

Берёт реальные расшифровки из замера и прогоняет через модель. Здесь нет
механической метрики: выход обязан отличаться от входа, «правильного ответа»
не существует. Поэтому вывод — таблица «было / стало» для оценки глазами.

    python llm/cleanup_probe.py [модель]
"""
import json
import sys
import time
from pathlib import Path

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

ROOT = Path(__file__).parent.parent
SOURCE = ROOT / "bench/results/whisper-large-v3-turbo_prompt.json"
PROMPT = (Path(__file__).parent / "cleanup_prompt.txt").read_text(encoding="utf-8").strip()


def words(text: str) -> list[str]:
    return [w.strip(".,!?;:\"«»—-").lower() for w in text.split() if w.strip(".,!?;:\"«»—-")]


def distance(a: list[str], b: list[str]) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[len(b)]


def guard(raw: str, clean: str) -> tuple[str, str]:
    """Отбрасывает правку, если модель переписала текст, а не причесала.

    Без этого фичу нельзя включать: одна выдумка на десяток диктовок
    обесценивает девять удачных. Дешевле вернуть исходник.
    """
    if not clean:
        return raw, "пусто"
    a, b = words(raw), words(clean)
    if not a:
        return raw, "нечего чистить"
    # Кириллица пропала, а была — значит перевела на другой язык.
    had_cyr = any("а" <= c.lower() <= "я" for c in raw)
    has_cyr = any("а" <= c.lower() <= "я" for c in clean)
    if had_cyr and not has_cyr:
        return raw, "сменила язык"
    if len(b) > len(a) * 1.3 + 2:
        return raw, "дописала лишнее"
    if distance(a, b) > max(2, len(a) * 0.4):
        return raw, "переписала слишком много"
    return clean, ""


def main() -> int:
    repo = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    items = json.loads(SOURCE.read_text(encoding="utf-8"))["items"]

    print(f"Модель: {repo}\nЗагружаю...", flush=True)
    t0 = time.perf_counter()
    model, tokenizer = load(repo)
    print(f"готова за {time.perf_counter() - t0:.1f}s\n")

    out, times = [], []
    for item in items:
        raw = item["text"]
        messages = [
            {"role": "system", "content": PROMPT},
            {"role": "user", "content": raw},
        ]
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        t = time.perf_counter()
        clean = generate(model, tokenizer, prompt=prompt, max_tokens=200,
                         sampler=make_sampler(temp=0.0), verbose=False).strip()
        clean, rejected = guard(raw, clean)
        elapsed = time.perf_counter() - t
        times.append(elapsed)
        out.append({"file": item["file"], "raw": raw, "clean": clean,
                    "rejected": rejected, "seconds": round(elapsed, 2)})
        print(f"{item['file']}  {elapsed:5.2f}s{'  [правка отброшена: ' + rejected + ']' if rejected else ''}")
        print(f"   было:  {raw}")
        print(f"   стало: {clean}\n", flush=True)

    times.sort()
    median = times[len(times) // 2]
    print(f"Медиана: {median:.2f}s на фразу")
    dest = ROOT / f"llm/cleanup-{repo.split('/')[-1]}.json"
    dest.write_text(json.dumps({"model": repo, "median_seconds": round(median, 2), "items": out},
                               ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"→ {dest.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
