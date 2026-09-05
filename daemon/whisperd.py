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


def load_dictionary() -> str | None:
    """Читается на каждый запрос: правки словаря применяются без перезапуска.

    Живёт в папке приложения, а не в репозитории: это данные пользователя,
    и обновление кода не должно их затирать. При первом запуске кладётся
    образец из комплекта.
    """
    if not DICTIONARY.exists():
        try:
            DICTIONARY.parent.mkdir(parents=True, exist_ok=True)
            DICTIONARY.write_text(DICTIONARY_DEFAULT.read_text(encoding="utf-8"), encoding="utf-8")
            log(f"создан словарь по образцу: {DICTIONARY}")
        except OSError as exc:
            log(f"не удалось создать словарь: {exc}")
            return None
    try:
        text = DICTIONARY.read_text(encoding="utf-8").strip()
        return text or None
    except OSError:
        return None


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

    if "correct" in req:
        ok = store.correct(int(req["correct"]["id"]), req["correct"]["text"])
        return {"ok": ok}

    wav = req["wav"]
    started = time.perf_counter()
    result = transcribe(wav, path_or_hf_repo=MODEL, language=LANGUAGE,
                        initial_prompt=load_dictionary())
    raw = result["text"].strip()

    if is_hallucination(raw):
        ms = int((time.perf_counter() - started) * 1000)
        log(f"{Path(wav).name}  {ms}ms  отброшено как фантом: {raw[:40]}")
        return {"id": 0, "text": "", "raw": raw, "ms": ms, "rejected": "фантом"}

    text, rejected, proposal = raw, "", ""
    if req.get("polish"):
        import polish as polisher
        text, rejected, proposal = polisher.polish(raw)

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
