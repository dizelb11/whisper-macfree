"""Причёсывание расшифровки локальной моделью.

Модель грузится лениво — при первом обращении. Кто причёсыванием не
пользуется, не платит за неё ни памятью (~2.5 ГБ), ни временем старта.

Ключевая часть здесь не промпт, а guard(): правка отбрасывается, если модель
не причесала текст, а переписала. Без этого фичу нельзя включать — одна
выдумка на десяток диктовок обесценивает девять удачных.
"""
from pathlib import Path

MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
PROMPT_FILE = Path(__file__).parent.parent / "llm" / "cleanup_prompt.txt"

_model = None
_tokenizer = None


def _load():
    global _model, _tokenizer
    if _model is None:
        from mlx_lm import load
        _model, _tokenizer = load(MODEL)
    return _model, _tokenizer


def _words(text: str) -> list[str]:
    strip = ".,!?;:\"«»—-"
    return [w.strip(strip).lower() for w in text.split() if w.strip(strip)]


def _distance(a: list[str], b: list[str]) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[len(b)]


def guard(raw: str, clean: str) -> tuple[str, str]:
    """Возвращает (текст, причина отказа). Пустая причина — правка принята."""
    if not clean:
        return raw, "пусто"
    a, b = _words(raw), _words(clean)
    if not a:
        return raw, "нечего чистить"
    had_cyr = any("а" <= c.lower() <= "я" for c in raw)
    has_cyr = any("а" <= c.lower() <= "я" for c in clean)
    if had_cyr and not has_cyr:
        return raw, "сменила язык"
    if len(b) > len(a) * 1.3 + 2:
        return raw, "дописала лишнее"
    if _distance(a, b) > max(2, len(a) * 0.4):
        return raw, "переписала слишком много"
    return clean, ""


def polish(text: str) -> tuple[str, str, str]:
    """Возвращает (итоговый текст, причина отказа, предложение модели)."""
    if not text.strip():
        return text, "", ""
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = _load()
    messages = [
        {"role": "system", "content": PROMPT_FILE.read_text(encoding="utf-8").strip()},
        {"role": "user", "content": text},
    ]
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    out = generate(model, tokenizer, prompt=prompt, max_tokens=300,
                   sampler=make_sampler(temp=0.0), verbose=False).strip()
    final, rejected = guard(text, out)
    return final, rejected, out
