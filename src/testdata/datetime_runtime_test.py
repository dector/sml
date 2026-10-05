"""Run with python3 src/testdata/datetime_runtime_test.py (SQLite STRICT required)."""
import datetime
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/datetime.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
db.execute('INSERT INTO event DEFAULT VALUES')
at, now, optional, raw = db.execute('SELECT at, created_at, optional, raw FROM event').fetchone()
assert at == '2000-02-29T23:59:59Z' and optional is None and raw == '0001-01-01T00:00:00Z'
assert len(now) == 20
datetime.datetime.strptime(now, '%Y-%m-%dT%H:%M:%SZ')

def rejects(statement, args=()):
    try:
        db.execute(statement, args)
    except sqlite3.IntegrityError:
        return
    raise AssertionError((statement, args))

valid = ['0001-01-01T00:00:00Z', '9999-12-31T23:59:59Z', '2000-02-29T00:00:00Z',
         '2024-02-29T00:00:00Z', '1900-02-28T00:00:00Z', '2023-04-30T00:00:00Z']
invalid = ['', '0000-01-01T00:00:00Z', '10000-01-01T00:00:00Z',
           '1900-02-29T00:00:00Z', '2100-02-29T00:00:00Z', '2023-02-29T00:00:00Z',
           '2024-02-30T00:00:00Z', '2023-04-31T00:00:00Z', '2023-00-01T00:00:00Z',
           '2023-13-01T00:00:00Z', '2023-01-00T00:00:00Z', '2023-01-32T00:00:00Z',
           '2023-01-01T24:00:00Z', '2023-01-01T00:60:00Z', '2023-01-01T00:00:60Z',
           '2023-01-01T00:00:00.000Z', '2023-01-01T00:00:00+00:00',
           '2023-01-01T00:00:00z', '2023-01-01t00:00:00Z', '2023-1-01T00:00:00Z',
           '2023-01-01 00:00:00Z', '2023-01-01T00:00:00Z ', '2023-01-01T00:00:00Z\0',
           '2023-01-01T00:00:\000Z', 'abcd-ef-ghTij:kl:mnZ', '2023-01-01T00:00:00', 1, 1.5, b'x']
for value in valid:
    db.execute('UPDATE event SET optional = ?', (value,))
for value in invalid:
    rejects('UPDATE event SET optional = ?', (value,))
db.execute('UPDATE event SET optional = NULL')
rejects('UPDATE event SET at = NULL')
rejects('INSERT INTO pair DEFAULT VALUES')
db.execute('INSERT INTO pair VALUES (?, ?)', valid[:2])
rejects('INSERT INTO pair VALUES (?, ?)', valid[:2])
assert 'AUTOINCREMENT' not in sql

# Raw SQL defaults are not statically evaluated, but runtime CHECKs reject them.
for expression in ["'1900-02-29T00:00:00Z'", "'2024-02-29T00:00:00.000Z'", '42']:
    changed = sql.replace("('0001-01-01T00:00:00Z')", '(' + expression + ')')
    other = sqlite3.connect(':memory:')
    other.executescript(changed)
    try:
        other.execute('INSERT INTO event DEFAULT VALUES')
    except sqlite3.IntegrityError:
        pass
    else:
        raise AssertionError(expression)
    finally:
        other.close()

# Exhaustive date boundary agreement with Python's proleptic Gregorian calendar.
for year in [1, 4, 100, 400, 1582, 1900, 2000, 2024, 2100, 9999]:
    for month in range(1, 13):
        for day in range(28, 33):
            value = f'{year:04}-{month:02}-{day:02}T00:00:00Z'
            try:
                datetime.date(year, month, day)
            except ValueError:
                rejects('UPDATE event SET optional = ?', (value,))
            else:
                db.execute('UPDATE event SET optional = ?', (value,))
print('datetime SQLite runtime checks passed')
