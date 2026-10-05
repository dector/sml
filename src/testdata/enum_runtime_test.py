"""Run with python3 src/testdata/enum_runtime_test.py (SQLite STRICT required)."""
from pathlib import Path
import sqlite3

SQL = (Path(__file__).parent / "parser" / "enum.expect.sql").read_text()


def rejected(db, sql, parameters=()):
    try:
        db.execute(sql, parameters)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f"Unexpectedly accepted: {sql}, {parameters!r}")


for encoding in ("UTF-8", "UTF-16le", "UTF-16be"):
    with sqlite3.connect(":memory:") as db:
        db.execute(f"PRAGMA encoding = '{encoding}'")
        db.executescript(SQL)
        db.execute("INSERT INTO choice DEFAULT VALUES")
        assert db.execute('SELECT key, "select", optional, nul FROM choice').fetchone() == (
            "draft", "true", None, "a\x00雪"
        )
        rejected(db, "INSERT INTO choice DEFAULT VALUES")
        for value in ("true", "false", "_", "a--b", "", "null", "it's ready", "tick`inside", "hash`#inside", "雪😀", "a\x00雪"):
            db.execute('UPDATE choice SET "select" = ?', (value,))
            assert db.execute('SELECT "select" FROM choice').fetchone()[0] == value
        for value in (None, "TRUE", "a", "a\x00", "a\x00雪suffix", "a\x00雪\x00", "unknown", 1, 1.5, b"true"):
            rejected(db, 'UPDATE choice SET "select" = ?', (value,))
        for value in (None, "yes", "no"):
            db.execute("UPDATE choice SET optional = ?", (value,))
        for value in ("YES", "", "null", b"yes", 0):
            rejected(db, "UPDATE choice SET optional = ?", (value,))
        for value in ("", "a\x00雪"):
            db.execute("UPDATE choice SET nul = ?", (value,))
        for value in (None, "a", "a\x00", "a\x00雪suffix"):
            rejected(db, "UPDATE choice SET nul = ?", (value,))
        rejected(db, "INSERT INTO choice(key) VALUES (NULL)")
        rejected(db, "INSERT INTO choice(key) VALUES ('unknown')")
        db.execute("INSERT INTO choice(key) VALUES ('published')")
        rejected(db, "INSERT INTO choice(key) VALUES ('published')")
        assert "AUTOINCREMENT" not in SQL
        db.execute("INSERT INTO pair DEFAULT VALUES")
        rejected(db, "INSERT INTO pair DEFAULT VALUES")
        db.execute("INSERT INTO pair VALUES ('B', 'y')")
        rejected(db, "INSERT INTO pair VALUES (NULL, 'x')")
        rejected(db, "INSERT INTO pair VALUES ('A', NULL)")
        rejected(db, "INSERT INTO pair VALUES ('C', 'x')")

print("SQLite enum runtime checks passed (UTF-8, UTF-16le, UTF-16be)")
