#!/usr/bin/env python3
"""Демон распознавания: держит модель в памяти и отвечает через Unix-сокет.

Модель грузится один раз при старте. Приложение шлёт путь к WAV, получает
текст. Без этого пришлось бы поднимать модель на каждую диктовку — несколько
секунд вместо полусекунды.

Здесь же живут история диктовок и причёсывание локальной моделью: приложение
остаётся тонким, а промпт и словарь можно менять без его пересборки, то есть
без повторной выдачи Универсального доступа.

Протокол — JSON построчно:
    ->  {"wav": "/путь.wav", "polish": false}
    <-  {"id": 12, "text": "...", "raw": "...", "ms": 580, "rejected": ""}
    ->  {"history": {"limit": 50}}
    <-  {"items": [...]}
    ->  {"correct": {"id": 12, "text": "исправленный текст"}}
    <-  {"ok": true}
    ->  {"ping": true}
    <-  {"ready": true, "model": "...", "stats": {...}}
"""
import json
import os
import re
import socket
import sys
import time
from pathlib import Path

import store

MODEL = "mlx-community/whisper-large-v3-turbo"
LANGUAGE = "ru"
STATE = Path.home() / "Library/Application Support/whisper-local"
SOCKET = STATE / "whisperd.sock"
DICTIONARY = STATE / "dictionary.txt"
DICTIONARY_DEFAULT = Path(__file__).parent / "dictionary.default.txt"
HALLUCINATIONS = Path(__file__).parent / "hallucinations.txt"


def log(msg: str) -> None:
    print(f"[whisperd] {msg}", file=sys.stderr, flush=True)


# Окно подсказки Whisper — 224 токена. Держим запас: русские слова
# дробятся на несколько токенов, и переполнение молча обрежет хвост.
PROMPT_WORD_LIMIT = 120


def seed_terms_if_needed() -> None:
    """Первое наполнение словаря: из файла пользователя, иначе из образца."""
    store.migrate_terms()
    if not store.words_empty():
        return
    source = DICTIONARY if DICTIONARY.exists() else DICTIONARY_DEFAULT
    try:
        words = [w.strip() for w in source.read_text(encoding="utf-8").replace("\n", " ").split(",")]
    except OSError:
        return
    added = store.seed_words([w for w in words if w and not w.startswith("#")])
    log(f"словарь наполнен из {source.name}: {added} терминов")


def build_prompt() -> str | None:
    """Подсказка модели.

    Берём и слова, и правые части замен: если пользователь завёл замену на
    "nginx", это правильное написание стоит подсказать в любом случае.
    """
    seen, out = set(), []
    for value in [r["word"] for r in store.words()] + [r["replacement"] for r in store.fixes()]:
        key = value.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(value)
        if len(out) >= PROMPT_WORD_LIMIT:
            break
    return ", ".join(out) + "." if out else None


def apply_terms(text: str) -> tuple[str, list[str]]:
    """Замена известных ослышек в готовом тексте.

    Только слово целиком: подстрочная замена испортила бы нормальные слова,
    внутри которых случайно оказался алиас.
    """
    applied = []
    for row in store.fixes():
        heard = row["heard"].strip()
        if not heard:
            continue
        pattern = re.compile(r"(?<!\w)" + re.escape(heard) + r"(?!\w)", re.IGNORECASE)
        replaced, count = pattern.subn(row["replacement"], text)
        if count:
            applied.append(f"{heard} → {row['replacement']}")
            text = replaced
    return text, applied


def is_hallucination(text: str) -> bool:
    """Whisper на тишине уверенно выдаёт фразы из субтитров.

    Сверяем целиком, а не по вхождению: "спасибо за просмотр" внутри реальной
    диктовки — законный текст, и выкусывать его нельзя.
    """
    norm = "".join(c for c in text.lower().replace("ё", "е") if c.isalnum() or c.isspace())
    norm = " ".join(norm.split())
    if not norm:
        return True
    try:
        lines = HALLUCINATIONS.read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        phrase = "".join(c for c in line if c.isalnum() or c.isspace())
        if norm == " ".join(phrase.split()):
            return True
    return False


def handle(req: dict, transcribe) -> dict:
    if req.get("ping"):
        return {"ready": True, "model": MODEL, "stats": store.stats()}

    if "history" in req:
        limit = int(req["history"].get("limit", 50))
        return {"items": store.recent(min(limit, 500))}

    if "words" in req:
        return {"items": store.words()}

    if "word_save" in req:
        w = req["word_save"]
        return {"id": store.word_save(w.get("id"), w.get("word", ""))}

    if "word_delete" in req:
        store.word_delete(int(req["word_delete"]["id"]))
        return {"ok": True}

    if "fixes" in req:
        return {"items": store.fixes()}

    if "fix_save" in req:
        f = req["fix_save"]
        return {"id": store.fix_save(f.get("id"), f.get("heard", ""), f.get("replacement", ""))}

    if "fix_delete" in req:
        store.fix_delete(int(req["fix_delete"]["id"]))
        return {"ok": True}

    if "correct" in req:
        ok = store.correct(int(req["correct"]["id"]), req["correct"]["text"])
        return {"ok": ok}

    wav = req["wav"]
    started = time.perf_counter()
    result = transcribe(wav, path_or_hf_repo=MODEL, language=LANGUAGE,
                        initial_prompt=build_prompt())
    raw = result["text"].strip()

    if is_hallucination(raw):
        ms = int((time.perf_counter() - started) * 1000)
        log(f"{Path(wav).name}  {ms}ms  отброшено как фантом: {raw[:40]}")
        return {"id": 0, "text": "", "raw": raw, "ms": ms, "rejected": "фантом"}

    # Замена ослышек идёт до причёсывания: модели лучше достаётся уже
    # починенный текст, иначе она примется угадывать исковерканное слово.
    text, applied = apply_terms(raw)
    if applied:
        log(f"словарь: {', '.join(applied)}")
    rejected, proposal = "", ""
    if req.get("polish"):
        import polish as polisher
        text, rejected, proposal = polisher.polish(text)

    ms = int((time.perf_counter() - started) * 1000)
    row_id = store.add(raw=raw, final=text, polished=bool(req.get("polish")), ms=ms,
                       proposal=proposal, rejected=rejected)
    note = f"  [правка отброшена: {rejected}]" if rejected else ""
    log(f"{Path(wav).name}  {ms}ms  {text[:60]}{note}")
    return {"id": row_id, "text": text, "raw": raw, "ms": ms, "rejected": rejected}


def serve() -> int:
    import mlx_whisper

    STATE.mkdir(parents=True, exist_ok=True)
    if SOCKET.exists():
        SOCKET.unlink()

    log(f"загружаю {MODEL}...")
    t0 = time.perf_counter()
    # Прогрев: первый вызов тянет и распаковывает веса. Делаем его до того,
    # как приложение пришлёт первый запрос, иначе первая диктовка встанет.
    silence = STATE / "warmup.wav"
    if not silence.exists():
        os.system(f'ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 0.5 -ar 16000 -ac 1 -y "{silence}" 2>/dev/null')
    mlx_whisper.transcribe(str(silence), path_or_hf_repo=MODEL, language=LANGUAGE)
    log(f"модель готова за {time.perf_counter() - t0:.1f}s")
    seed_terms_if_needed()

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(SOCKET))
    os.chmod(SOCKET, 0o600)
    srv.listen(4)
    log(f"слушаю {SOCKET}")

    while True:
        conn, _ = srv.accept()
        with conn:
            try:
                data = conn.makefile("rb").readline()
                if not data:
                    continue
                reply = handle(json.loads(data), mlx_whisper.transcribe)
            except Exception as exc:  # noqa: BLE001 — клиенту нужна причина, демон не падает
                reply = {"error": f"{type(exc).__name__}: {exc}"}
                log(f"ОШИБКА: {reply['error']}")
            conn.sendall((json.dumps(reply, ensure_ascii=False) + "\n").encode())


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    try:
        sys.exit(serve())
    except KeyboardInterrupt:
        log("остановлен")
