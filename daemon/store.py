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
CREATE TABLE IF NOT EXISTS terms (
    id         INTEGER PRIMARY KEY,
    canonical  TEXT    NOT NULL,               -- как надо: "Claude Code"
    alias      TEXT    NOT NULL DEFAULT '',    -- как слышится: "клод кот"
    enabled    INTEGER NOT NULL DEFAULT 1,
    created_at TEXT    NOT NULL,
    UNIQUE(canonical, alias)
);
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


# --- Словарь ---------------------------------------------------------------
#
# Одна таблица кормит два разных механизма:
#   canonical — уходит в подсказку модели распознавания, чтобы ошибка
#               не случилась вовсе;
#   alias     — заменяется на canonical уже в готовом тексте, если ошибка
#               всё-таки проскочила.
# Строка без alias работает только как подсказка.


def terms(enabled_only: bool = False) -> list[dict]:
    with connect() as conn:
        sql = "SELECT id, canonical, alias, enabled FROM terms"
        if enabled_only:
            sql += " WHERE enabled = 1"
        sql += " ORDER BY canonical COLLATE NOCASE, alias"
        return [dict(r) for r in conn.execute(sql)]


def term_save(term_id: int | None, canonical: str, alias: str, enabled: bool) -> int | None:
    canonical, alias = canonical.strip(), alias.strip()
    if not canonical:
        return None
    with connect() as conn:
        if term_id:
            conn.execute(
                "UPDATE terms SET canonical = ?, alias = ?, enabled = ? WHERE id = ?",
                (canonical, alias, int(enabled), term_id),
            )
            return term_id
        cur = conn.execute(
            "INSERT OR IGNORE INTO terms (canonical, alias, enabled, created_at) VALUES (?,?,?,?)",
            (canonical, alias, int(enabled), now()),
        )
        if cur.lastrowid:
            return cur.lastrowid
        row = conn.execute(
            "SELECT id FROM terms WHERE canonical = ? AND alias = ?", (canonical, alias)
        ).fetchone()
        return row["id"] if row else None


def term_delete(term_id: int) -> None:
    with connect() as conn:
        conn.execute("DELETE FROM terms WHERE id = ?", (term_id,))


def seed_terms(words: list[str]) -> int:
    """Первичное наполнение. Возвращает число добавленных."""
    added = 0
    with connect() as conn:
        for word in words:
            word = word.strip(" .,\n")
            if not word:
                continue
            cur = conn.execute(
                "INSERT OR IGNORE INTO terms (canonical, alias, enabled, created_at)"
                " VALUES (?,?,1,?)", (word, "", now()))
            added += cur.rowcount
    return added


def terms_empty() -> bool:
    with connect() as conn:
        return conn.execute("SELECT COUNT(*) n FROM terms").fetchone()["n"] == 0
