"""Хранилище диктовок. Живёт в демоне, а не в приложении.

Так история переживает пересборки приложения, а словарное обучение —
которое тоже здесь — читает её напрямую, без обмена через сокет.
"""
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

DB = Path.home() / "Library/Application Support/whisper-local/history.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS dictations (
    id         INTEGER PRIMARY KEY,
    created_at TEXT    NOT NULL,
    raw        TEXT    NOT NULL,  -- как расслышал Whisper
    final      TEXT    NOT NULL,  -- что реально вставилось
    polished   INTEGER NOT NULL DEFAULT 0,
    ms         INTEGER NOT NULL DEFAULT 0,
    proposal   TEXT    NOT NULL DEFAULT '',  -- что предложила модель
    rejected   TEXT    NOT NULL DEFAULT ''   -- почему предложение отклонено
);
CREATE TABLE IF NOT EXISTS corrections (
    id           INTEGER PRIMARY KEY,
    dictation_id INTEGER NOT NULL REFERENCES dictations(id),
    before       TEXT    NOT NULL,
    after        TEXT    NOT NULL,
    created_at   TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_dictations_created ON dictations(created_at DESC);
"""


def connect() -> sqlite3.Connection:
    DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    # Миграция: у баз, созданных до появления колонок, их надо доклеить.
    existing = {r["name"] for r in conn.execute("PRAGMA table_info(dictations)")}
    for column in ("proposal", "rejected"):
        if column not in existing:
            conn.execute(f"ALTER TABLE dictations ADD COLUMN {column} TEXT NOT NULL DEFAULT ''")
    return conn


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def add(raw: str, final: str, polished: bool, ms: int,
        proposal: str = "", rejected: str = "") -> int:
    """proposal хранится всегда, в том числе отклонённое.

    Иначе отклонённая правка невидима: в final лежит исходник, и не понять,
    что модель что-то предлагала и была отменена. Её работа должна быть
    проверяемой — мы знаем, что она иногда врёт.
    """
    with connect() as conn:
        cur = conn.execute(
            "INSERT INTO dictations (created_at, raw, final, polished, ms, proposal, rejected)"
            " VALUES (?,?,?,?,?,?,?)",
            (now(), raw, final, int(polished), ms, proposal, rejected),
        )
        return cur.lastrowid


def recent(limit: int = 50) -> list[dict]:
    with connect() as conn:
        rows = conn.execute(
            "SELECT id, created_at, raw, final, polished, ms, proposal, rejected FROM dictations"
            " ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return [dict(r) for r in rows]


def correct(dictation_id: int, text: str) -> bool:
    """Правка диктовки. Пара «было/стало» сохраняется — из неё потом
    строятся алиасы словаря, чтобы ту же ошибку не повторять."""
    with connect() as conn:
        row = conn.execute("SELECT final FROM dictations WHERE id = ?", (dictation_id,)).fetchone()
        if row is None:
            return False
        if row["final"] != text:
            conn.execute(
                "INSERT INTO corrections (dictation_id, before, after, created_at) VALUES (?,?,?,?)",
                (dictation_id, row["final"], text, now()),
            )
            conn.execute("UPDATE dictations SET final = ? WHERE id = ?", (text, dictation_id))
        return True


def stats() -> dict:
    with connect() as conn:
        d = conn.execute("SELECT COUNT(*) n FROM dictations").fetchone()["n"]
        c = conn.execute("SELECT COUNT(*) n FROM corrections").fetchone()["n"]
        return {"dictations": d, "corrections": c}
