"""Connection collections preserve tuples; singularity comes from stored UNIQUE."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/connection_relationships.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
assert [r[0] for r in db.execute("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")] == ['book', 'following', 'reader', 'single', 'trio']
assert [r[1] for r in db.execute('PRAGMA table_info(following)')] == ['left_reader', 'right_reader']


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement}')


db.execute('INSERT INTO reader VALUES (1), (2), (3)')
db.execute('INSERT INTO book VALUES (1), (2)')
db.execute('INSERT INTO following VALUES (1, 2), (1, 3), (2, 1), (1, 1)')
rejected('INSERT INTO following VALUES (1, 2)')
rejected('INSERT INTO following VALUES (1, 99)')
rejected('INSERT INTO following VALUES (99, 1)')
# A third endpoint distinguishes tuples. A collection does not imply DISTINCT.
db.execute('INSERT INTO trio VALUES (1, 2, 1), (1, 2, 3)')
assert list(db.execute('SELECT second FROM trio WHERE first=1')) == [(2,), (2,)]
rejected('INSERT INTO trio VALUES (1, 2, 1)')
db.execute('INSERT INTO single VALUES (1, 1)')
rejected('INSERT INTO single VALUES (1, 2)')
rejected('INSERT INTO single VALUES (2, 99)')
assert list(db.execute('SELECT book FROM single WHERE reader=1')) == [(1,)]
assert list(db.execute('SELECT book FROM single WHERE reader=3')) == []
assert not list(db.execute('PRAGMA foreign_key_check'))
print('connection relationship runtime checks passed')
