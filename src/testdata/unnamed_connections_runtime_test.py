"""Explicit unnamed canonical keys, SQL aliases and reverse lookup indexes."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/unnamed_connections.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
db.execute('INSERT INTO "Writer" (id) VALUES (1)')
db.execute('INSERT INTO book (id) VALUES (2)')
db.execute('INSERT INTO "Library Links" (author_id, volume) VALUES (1, 2)')
assert db.execute('SELECT note FROM "Library Links"').fetchone() == ('ready',)
for statement in (
    'INSERT INTO "Library Links" (author_id, volume) VALUES (1, 2)',
    'INSERT INTO "Library Links" (author_id, volume) VALUES (9, 2)',
    'INSERT INTO "Library Links" (author_id) VALUES (1)',
    'DELETE FROM "Writer" WHERE id = 1',
    'DELETE FROM book WHERE id = 2',
):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        pass
    else:
        raise AssertionError(statement)
plan = db.execute('EXPLAIN QUERY PLAN SELECT author_id FROM "Library Links" WHERE volume = 2').fetchall()
assert any('Library Links_volume_idx' in row[3] for row in plan), plan
assert db.execute('PRAGMA foreign_key_check').fetchall() == []
print('unnamed connection runtime checks passed')
