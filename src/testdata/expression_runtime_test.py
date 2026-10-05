"""Execute standalone expression SQL fixtures (also verified by Zig emission)."""
import itertools
import sqlite3
from pathlib import Path

fixtures = dict(
    line.split("\t", 1)
    for line in (Path(__file__).parent / "expression/expressions.tsv")
    .read_text().splitlines()
)


def sql_not(value):
    return None if value is None else int(not value)


def sql_and(a, b):
    if a == 0 or b == 0:
        return 0
    return None if a is None or b is None else 1


def sql_or(a, b):
    if a == 1 or b == 1:
        return 1
    return None if a is None or b is None else 0


def sql_equal(a, b):
    return None if a is None or b is None else int(a == b)


checks = {
    "a && b": sql_and,
    "a || b": sql_or,
    "!a": lambda a, b: sql_not(a),
    "!a == b": lambda a, b: sql_equal(sql_not(a), b),
    "!(a == b)": lambda a, b: sql_not(sql_equal(a, b)),
    "a != null": lambda a, b: int(a is not None),
    "(null) == (a)": lambda a, b: int(a is None),
    "(null) != (a)": lambda a, b: int(a is not None),
    "null == null": lambda a, b: 1,
    "a == b": sql_equal,
    "a != b": lambda a, b: sql_not(sql_equal(a, b)),
    "a && !b || a == null": lambda a, b: sql_or(
        sql_and(a, sql_not(b)), int(a is None)
    ),
    "`_ + 1`": lambda a, b: 8,
    "`NULL` == null": lambda a, b: 1,
    "_ != null": lambda a, b: int(a is not None),
    "-7": lambda a, b: -7,
    "1.25": lambda a, b: 1.25,
    "true": lambda a, b: 1,
    "false": lambda a, b: 0,
    "'O''Brien'": lambda a, b: "O'Brien",
    "'hé\\0''尾'": lambda a, b: "hé\0'尾",
    "1 < 2 && 2 <= 3 || 4 > 3 && 4 >= 4": lambda a, b: 1,
}
assert fixtures.keys() == checks.keys()
for encoding in ("UTF-8", "UTF-16le", "UTF-16be"):
    with sqlite3.connect(":memory:") as db:
        db.execute(f"PRAGMA encoding = '{encoding}'")
        db.execute('CREATE TABLE t ("a"" SQL" INTEGER, "b SQL" INTEGER, _ INTEGER)')
        for a, b in itertools.product((None, 0, 1), repeat=2):
            db.execute("DELETE FROM t")
            db.execute("INSERT INTO t VALUES (?, ?, 7)", (a, b))
            for source, sql in fixtures.items():
                actual = db.execute(f"SELECT {sql} FROM t").fetchone()[0]
                expected = checks[source](a, b)
                assert actual == expected, (encoding, source, a, b, actual, expected)
print("expression truth tables and text encodings: OK")
