"""Canonical Gregorian dates under all SQLite database encodings."""
import datetime
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/date.expect.sql').read_text()
valid = ['0001-01-01', '9999-12-31', '2000-02-29', '2024-02-29', '1900-02-28']
invalid = ['', '0000-01-01', '10000-01-01', '1900-02-29', '2100-02-29',
           '2023-02-29', '2024-02-30', '2023-04-31', '2023-00-01', '2023-13-01',
           '2023-01-00', '2023-01-32', '2023-1-01', '2023-01-01 ',
           '2023-01-01T00:00:00Z', '2023-01-01+00:00', '２０２３-01-01',
           '2023-01-01\0', '2023-01-\0001', 1, 1.5, b'2023-01-01']
# Unicode code points whose encoded bytes look like ASCII digits/separators.
invalid += [''.join(chr(ord(c) + 0x100) for c in '2023-01-01'),
            ''.join(chr(ord(c) * 256 + ord(c)) for c in '2023-01-01')]


def rejects(db, statement, args=()):
    try:
        db.execute(statement, args)
    except sqlite3.IntegrityError:
        return
    raise AssertionError((statement, args))


for encoding in ['UTF-8', 'UTF-16le', 'UTF-16be']:
    db = sqlite3.connect(':memory:')
    db.execute(f"PRAGMA encoding = '{encoding}'")
    db.executescript(sql)
    assert db.execute('PRAGMA encoding').fetchone()[0].lower() == encoding.lower()
    db.execute('INSERT INTO day DEFAULT VALUES')
    assert db.execute('SELECT * FROM day').fetchone() == ('2000-02-29', None, '0001-01-01')
    db.execute('INSERT INTO ref DEFAULT VALUES')
    rejects(db, 'INSERT INTO ref VALUES (?)', ('0001-01-01',))
    rejects(db, 'UPDATE ref SET day = ?', ('0000-01-01',))
    rejects(db, 'UPDATE day SET at = NULL')
    rejects(db, 'INSERT INTO pair DEFAULT VALUES')
    db.execute('INSERT INTO pair VALUES (?, ?)', valid[:2])
    rejects(db, 'INSERT INTO pair VALUES (?, ?)', valid[:2])
    for value in valid:
        db.execute('UPDATE day SET optional = ?', (value,))
        db.execute('INSERT INTO range VALUES (?, NULL)', (value,))
    for value in invalid:
        rejects(db, 'UPDATE day SET optional = ?', (value,))
        rejects(db, 'INSERT INTO range VALUES (?, NULL)', (value,))
    db.execute('UPDATE day SET optional = NULL')
    rejects(db, 'INSERT INTO range VALUES (?, ?)', ('2024-02-29', '2024-02-28'))
    db.execute('INSERT INTO range VALUES (?, ?)', ('2024-02-28', '2024-02-29'))
    for year in [1, 4, 100, 400, 1582, 1900, 2000, 2024, 2100, 9999]:
        for month in range(1, 13):
            for day in range(28, 33):
                value = f'{year:04}-{month:02}-{day:02}'
                try:
                    datetime.date(year, month, day)
                except ValueError:
                    rejects(db, 'UPDATE day SET optional = ?', (value,))
                else:
                    db.execute('UPDATE day SET optional = ?', (value,))
    db.close()
    for expression in ["'1900-02-29'", "'0000-01-01'", '42', "'2000-01-01' || char(0)"]:
        other = sqlite3.connect(':memory:')
        other.execute(f"PRAGMA encoding = '{encoding}'")
        other.executescript(sql.replace("('0001-01-01')", '(' + expression + ')'))
        rejects(other, 'INSERT INTO day DEFAULT VALUES')
        other.close()
assert 'AUTOINCREMENT' not in sql
print('date SQLite runtime checks passed (UTF-8, UTF-16le, UTF-16be)')
