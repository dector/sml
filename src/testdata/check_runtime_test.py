"""Run with python3 src/testdata/check_runtime_test.py (SQLite STRICT required)."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/checks.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
db.execute('INSERT INTO samples (required, present, other, label, empty) VALUES (1, 0, 2, ?, ?)', ('ok', ''))

def set_value(name, value, valid):
    try:
        db.execute(f'UPDATE samples SET {name} = ?', (value,))
    except sqlite3.IntegrityError:
        assert not valid, (name, value)
    else:
        assert valid, (name, value)

# UNKNOWN is accepted by CHECK. Nullability is independently enforced by NOT NULL.
for value in [None, 1, 9]:
    set_value('"opt""value"', value, True)
for value in [0, -1, 10]:
    set_value('"opt""value"', value, False)
for value in [None, -1, 11]:
    set_value('required', value, False)
set_value('required', 0, True)
set_value('present', None, False)  # != null lowers to IS NOT NULL.
for value in [0, -1, 100]:
    set_value('present', value, True)
for value in [None, 1]:
    set_value('flag', value, True)
for value in [0, 2]:
    set_value('flag', value, False)
for value in [None, 'ready']:
    set_value('state', value, True)
for value in ['done', 'unknown']:
    set_value('state', value, False)
for value in [None, '2000-02-29T00:00:00Z']:
    set_value('created', value, True)
for value in ['1999-01-01T00:00:00Z', '2001-02-29T00:00:00Z']:
    set_value('created', value, False)
set_value('other', -1, False)  # Trusted SQL can refer to another column.
set_value('other', 10, True)
for value in ['bad', 'no', None]:
    set_value('label', value, False)
set_value('label', 'fine', True)
print('Field CHECK SQLite runtime checks passed')
