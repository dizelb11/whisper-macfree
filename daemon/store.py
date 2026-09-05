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
-- Два разных инструмента, поэтому две таблицы, а не одна с необязательным
-- полем: так у каждого одна понятная задача.
CREATE TABLE IF NOT EXISTS words (
    id         INTEGER PRIMARY KEY,
    word       TEXT    NOT NULL UNIQUE,        -- "Claude Code" — подсказка модели
    created_at TEXT    NOT NULL
);
CREATE TABLE IF NOT EXISTS fixes (
    id          INTEGER PRIMARY KEY,
    heard       TEXT    NOT NULL UNIQUE,       -- "клод кот" — что слышится
    replacement TEXT    NOT NULL,              -- "Claude Code" — на что менять
    created_at  TEXT    NOT NULL
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
# words — слова, которые модель распознавания должна знать заранее. Зная
#         слово, она перестаёт его коверкать, и чинить нечего.
# fixes — замены в готовом тексте для случаев, когда подсказка не помогла.
#
# В подсказку уходят и слова, и правые части замен: правильное написание
# полезно подсказать в любом случае.


def words() -> list[dict]:
    with connect() as conn:
        return [dict(r) for r in conn.execute(
            "SELECT id, word FROM words ORDER BY word COLLATE NOCASE")]


def word_save(word_id: int | None, word: str) -> int | None:
    word = word.strip(" .,")
    if not word:
        return None
    with connect() as conn:
        if word_id and word_id > 0:
            conn.execute("UPDATE words SET word = ? WHERE id = ?", (word, word_id))
            return word_id
        cur = conn.execute("INSERT OR IGNORE INTO words (word, created_at) VALUES (?,?)",
                           (word, now()))
        if cur.lastrowid:
            return cur.lastrowid
        row = conn.execute("SELECT id FROM words WHERE word = ?", (word,)).fetchone()
        return row["id"] if row else None


def word_delete(word_id: int) -> None:
    with connect() as conn:
        conn.execute("DELETE FROM words WHERE id = ?", (word_id,))


def fixes() -> list[dict]:
    with connect() as conn:
        return [dict(r) for r in conn.execute(
            "SELECT id, heard, replacement FROM fixes ORDER BY heard COLLATE NOCASE")]


def fix_save(fix_id: int | None, heard: str, replacement: str) -> int | None:
    heard, replacement = heard.strip(), replacement.strip()
    if not heard or not replacement:
        return None
    with connect() as conn:
        if fix_id and fix_id > 0:
            conn.execute("UPDATE fixes SET heard = ?, replacement = ? WHERE id = ?",
                         (heard, replacement, fix_id))
            return fix_id
        cur = conn.execute(
            "INSERT OR IGNORE INTO fixes (heard, replacement, created_at) VALUES (?,?,?)",
            (heard, replacement, now()))
        if cur.lastrowid:
            return cur.lastrowid
        row = conn.execute("SELECT id FROM fixes WHERE heard = ?", (heard,)).fetchone()
        return row["id"] if row else None


def fix_delete(fix_id: int) -> None:
    with connect() as conn:
        conn.execute("DELETE FROM fixes WHERE id = ?", (fix_id,))


def seed_words(items: list[str]) -> int:
    added = 0
    with connect() as conn:
        for item in items:
            item = item.strip(" .,\n")
            if item:
                added += conn.execute(
                    "INSERT OR IGNORE INTO words (word, created_at) VALUES (?,?)",
                    (item, now())).rowcount
    return added


def words_empty() -> bool:
    with connect() as conn:
        return conn.execute("SELECT COUNT(*) n FROM words").fetchone()["n"] == 0


def migrate_terms() -> None:
    """Перенос из прежней единой таблицы terms, если она осталась."""
    with connect() as conn:
        exists = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='terms'").fetchone()
        if not exists:
            return
        for row in conn.execute("SELECT canonical, alias FROM terms"):
            conn.execute("INSERT OR IGNORE INTO words (word, created_at) VALUES (?,?)",
                         (row["canonical"], now()))
            if row["alias"].strip():
                conn.execute(
                    "INSERT OR IGNORE INTO fixes (heard, replacement, created_at) VALUES (?,?,?)",
                    (row["alias"], row["canonical"], now()))
        conn.execute("DROP TABLE terms")
