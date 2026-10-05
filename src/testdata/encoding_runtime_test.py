"""Run with python3 src/testdata/encoding_runtime_test.py (SQLite STRICT required)."""
from pathlib import Path
import sqlite3

FIXTURES = Path(__file__).parent / "parser"


def rejected(connection, sql, parameters=()):
    try:
        connection.execute(sql, parameters)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f"Unexpectedly accepted: {sql}, {parameters!r}")


for encoding in ("UTF-8", "UTF-16le", "UTF-16be"):
    with sqlite3.connect(":memory:") as db:
        db.execute(f"PRAGMA encoding = '{encoding}'")
        db.executescript((FIXTURES / "boolean.expect.sql").read_text())
        db.execute("INSERT INTO flags DEFAULT VALUES")
        assert db.execute("SELECT enabled, disabled, optional, unknown FROM flags").fetchone() == (1, 0, None, None)
        for value in (0, 1):
            db.execute("UPDATE flags SET enabled = ?", (value,))
        for value in (None, 2, -1, "not boolean", b"0"):
            rejected(db, "UPDATE flags SET enabled = ?", (value,))
        db.execute("UPDATE flags SET optional = NULL")
        rejected(db, "UPDATE flags SET optional = 2")

    with sqlite3.connect(":memory:") as db:
        db.execute(f"PRAGMA encoding = '{encoding}'")
        db.executescript((FIXTURES / "datetime.expect.sql").read_text())
        db.execute("INSERT INTO event DEFAULT VALUES")
        now, raw = db.execute("SELECT created_at, raw FROM event").fetchone()
        assert len(now) == 20 and now.endswith("Z") and "." not in now
        assert raw == "0001-01-01T00:00:00Z"
        for value in (None, "0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "2000-02-29T12:34:56Z", "2024-02-29T00:00:00Z"):
            db.execute("UPDATE event SET optional = ?", (value,))
        for value in (
            "0000-01-01T00:00:00Z", "1900-02-29T00:00:00Z",
            "2023-02-29T00:00:00Z", "2024-04-31T00:00:00Z",
            "2024-00-01T00:00:00Z", "2024-13-01T00:00:00Z",
            "2024-01-00T00:00:00Z", "2024-01-01T24:00:00Z",
            "2024-01-01T00:60:00Z", "2024-01-01T00:00:60Z",
            "2024-01-01T00:00:00.000Z", "2024-01-01T00:00:00+00:00",
            "2024-01-01T00:00:00Z\x00", "2024-01-01T00:00:00Z\x00suffix",
            "２０２４-01-01T00:00:00Z", 123, b"2024-01-01T00:00:00Z",
        ):
            rejected(db, "UPDATE event SET optional = ?", (value,))
        rejected(db, "UPDATE event SET created_at = NULL")
        rejected(db, "UPDATE event SET at = NULL")
        db.execute("INSERT INTO pair VALUES ('2024-01-01T00:00:00Z', '2024-01-02T00:00:00Z')")
        rejected(db, "INSERT INTO pair VALUES (NULL, '2024-01-02T00:00:00Z')")
        rejected(db, "INSERT INTO pair VALUES ('2024-01-01T00:00:00Z', '2024-01-02T00:00:00Z')")

print("SQLite defaults runtime checks passed (UTF-8, UTF-16le, UTF-16be)")
