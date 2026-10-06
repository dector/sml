"""Generated-slot overrides keep ordinary stored FK metadata and semantics."""
import pathlib
import sqlite3

db = sqlite3.connect(':memory:')
db.executescript((pathlib.Path(__file__).parent / 'parser/generated_overrides.expect.sql').read_text())


def rejected(sql):
    try:
        db.execute(sql)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(sql)


for table, names, indexes in [
    ('pair', ('writer_id', 'status'), {('writer_id', 'status')}),
    ('self', ('first_id', 'right_id', 'context_id'), {('right_id', 'first_id'), ('context_id',)}),
]:
    info = list(db.execute(f'PRAGMA table_info("{table}")'))
    assert tuple(row[1] for row in info[:len(names)]) == names
    assert tuple(row[1] for row in sorted(info, key=lambda r: r[5]) if row[5]) == names
    actual = {tuple(row[2] for row in db.execute(f'PRAGMA index_info("{index[1]}")'))
              for index in db.execute(f'PRAGMA index_list("{table}")') if index[3] == 'c'}
    assert actual == indexes

assert '-- The writer override keeps its own docs.' in (pathlib.Path(__file__).parent / 'parser/generated_overrides.expect.sql').read_text()
db.execute('INSERT INTO author VALUES (1), (2), (3)')
db.execute("INSERT INTO state VALUES ('ready'), ('done')")
db.execute('INSERT INTO pair DEFAULT VALUES')
assert db.execute('SELECT * FROM pair').fetchone() == (1, 'ready', 2, 'unchanged')
rejected('INSERT INTO pair DEFAULT VALUES')
rejected("INSERT INTO pair VALUES (2, 'ready', 2, 'unchanged')")  # Field uniqueness.
rejected("INSERT INTO pair VALUES (2, 'unknown', 2, 'unchanged')")
rejected("INSERT INTO pair VALUES (0, 'done', 2, 'unchanged')")
rejected("INSERT INTO pair VALUES (NULL, 'done', 2, 'unchanged')")
rejected("DELETE FROM state WHERE code='ready'")  # Other key remains RESTRICT.
db.execute('DELETE FROM author WHERE "Actual Key"=1')  # Custom writer column CASCADE.
assert db.execute('SELECT count(*) FROM pair').fetchone() == (0,)
db.execute('INSERT INTO self(first_id, right_id) VALUES (2, 3)')
assert db.execute('SELECT * FROM self').fetchone() == (2, 3, 3, 'ready')
rejected('INSERT INTO self(first_id, right_id) VALUES (2, 3)')
rejected('INSERT INTO self(first_id) VALUES (2)')
rejected('DELETE FROM author WHERE "Actual Key"=3')
print('generated override runtime tests passed')
