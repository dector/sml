"""Partial indexes: SQLite metadata, query plan and active/deleted uniqueness."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/partial_index.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
rows = {r[1]: r for r in db.execute('PRAGMA index_list("record store")')}
assert set(rows) == {'active email', 'boolean lookup', 'raw lookup'}
assert all(r[4] == 1 for r in rows.values())
assert rows['active email'][2] == 1
assert rows['boolean lookup'][2] == rows['raw lookup'][2] == 0
assert [r[2] for r in db.execute('PRAGMA index_info("active email")')] == ['email']


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement}')


db.executemany('INSERT INTO "record store" VALUES (?, ?, ?, ?, ?)', [
    ('same', None, 1, 1, 2), ('same', 10, 1, 1, 2),
    ('same', 20, 0, 3, 2), (None, None, 1, 1, 2),
    (None, None, 1, 1, 2), ('other', None, 0, 3, 2),
])
rejected('INSERT INTO "record store" VALUES (\'same\', NULL, 1, 1, 2)')
rejected('UPDATE "record store" SET "deleted at" = NULL WHERE "deleted at" = 10')
rejected('UPDATE "record store" SET email = \'same\' WHERE email = \'other\'')
# Leaving the predicate frees the key. Entering it now succeeds.
db.execute('UPDATE "record store" SET "deleted at" = 30 WHERE email = \'same\' AND "deleted at" IS NULL')
db.execute('UPDATE "record store" SET "deleted at" = NULL WHERE "deleted at" = 10')
rejected('UPDATE "record store" SET "deleted at" = NULL WHERE "deleted at" = 20')
plan = list(db.execute('EXPLAIN QUERY PLAN SELECT email FROM "record store" WHERE email = \'same\' AND "deleted at" IS NULL'))
assert any('active email' in r[3] for r in plan), plan
print('partial index runtime checks passed')
