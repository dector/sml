"""Run with python3 src/testdata/boolean_runtime_test.py (SQLite STRICT required)."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/boolean.expect.sql').read_text()
assert 'WITHOUT ROWID' not in sql
assert sql.count('PRIMARY KEY') == 1  # Only the existing int identity.
db = sqlite3.connect(':memory:')
db.executescript(sql)
raw_name = '"a""b`c"'
db.execute(f'INSERT INTO flags ({raw_name}) VALUES (1)')
assert db.execute('SELECT id, enabled, disabled, optional, unknown FROM flags').fetchone() == (1, 1, 0, None, None)
for value in [0, 1, None]:
    db.execute('UPDATE flags SET optional = ?', (value,))
for value in [-1, 2, 1.5, 'true', 'false', b'\x01']:
    try:
        db.execute('UPDATE flags SET optional = ?', (value,))
    except sqlite3.IntegrityError:
        pass
    else:
        raise AssertionError(value)
try:
    db.execute('UPDATE flags SET enabled = NULL')
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError('nonnullable Boolean accepted NULL')
db.execute(f'INSERT INTO flags ({raw_name}) VALUES (0)')
assert db.execute('SELECT max(id) FROM flags').fetchone()[0] == 2
# Raw SQL default escape hatch is still subject to the Boolean CHECK.
other = sqlite3.connect(':memory:')
other.executescript(sql.replace('DEFAULT (1 = 1)', 'DEFAULT (2)'))
try:
    other.execute('INSERT INTO flags DEFAULT VALUES')
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError('raw SQL default bypassed Boolean CHECK')
print('Boolean SQLite runtime checks passed')
