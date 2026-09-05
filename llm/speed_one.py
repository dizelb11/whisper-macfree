#!/usr/bin/env python3
"""Один способ причёсывания за запуск — чтобы модели не толкались в памяти.

    python llm/speed_one.py base|draft|small
"""
import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "daemon"))
import store
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

PROMPT = (Path(__file__).parent / "cleanup_prompt.txt").read_text(encoding="utf-8").strip()
mode = sys.argv[1]
parts = [r["raw"] for r in store.recent(40) if len(r["raw"]) > 60]
text = " ".join(parts[:3])

repo = "mlx-community/Qwen3-1.7B-4bit" if mode == "small" else "mlx-community/Qwen3-4B-Instruct-2507-4bit"
model, tok = load(repo)
kwargs = {}
if mode == "draft":
    kwargs["draft_model"] = load("mlx-community/Qwen3-0.6B-4bit")[0]

messages = [{"role": "system", "content": PROMPT}, {"role": "user", "content": text}]
try:
    # Гибридные Qwen3 иначе начинают "размышлять" прямо в ответ.
    prompt = tok.apply_chat_template(messages, add_generation_prompt=True,
                                     enable_thinking=False)
except TypeError:
    prompt = tok.apply_chat_template(messages, add_generation_prompt=True)
t = time.perf_counter()
out = generate(model, tok, prompt=prompt, max_tokens=2048,
               sampler=make_sampler(temp=0.0), verbose=False, **kwargs).strip()
dt = time.perf_counter() - t
print(f"РЕЗУЛЬТАТ {mode}: {dt:.1f}s, сохранено {len(out.split())/len(text.split()):.0%}, "
      f"{len(tok.encode(out))/dt:.1f} ток/с")
print("НАЧАЛО:", out[:150].replace("\n", " "))
