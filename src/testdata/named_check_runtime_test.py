"""Run with python3 src/testdata/named_check_runtime_test.py (SQLite STRICT)."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/named_checks.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)


def reject(statement, values, name):
    try:
        db.execute(statement, values)
    except sqlite3.IntegrityError as error:
        assert str(error) == 'CHECK constraint failed: ' + name, str(error)
    else:
        raise AssertionError((statement, values, name))


insert = 'INSERT INTO "named ranges" VALUES (?, ?)'
for values in [(1, 9), (None, None), (None, 9)]:
    db.execute(insert, values)  # UNKNOWN remains accepted.
for values, name in [
    ((9, 2), 'range "order"'),
    ((-1, 9), 'nonnegative `lower`'),
    ((1, 100), 'upper ` limit'),
    ((1, None), 'upper required'),
]:
    reject(insert, values, name)
    reject('UPDATE "named ranges" SET "low value" = ?, "upper" = ?', values, name)

# Parent #name changes the table/column, not the constraint label.
reject('INSERT INTO flags VALUES (?)', (0,), 'enabled only')
db.execute('INSERT INTO flags VALUES (1)')
reject('UPDATE flags SET enabled = ?', (0,), 'enabled only')
db.execute('UPDATE flags SET enabled = NULL')
# Builtin bool enforcement stays unnamed and active.
try:
    db.execute('INSERT INTO flags VALUES (2)')
except sqlite3.IntegrityError as error:
    assert str(error).startswith('CHECK constraint failed: ')
else:
    raise AssertionError('builtin bool check missing')

# Quoted names are inert labels, never executable SQL. No metadata SQL parsing.
name = 'safe"); DROP TABLE flags; --'
reject('INSERT INTO safe VALUES (?)', (0,), name)
db.execute('INSERT INTO safe VALUES (1)')
reject('UPDATE safe SET n = ?', (0,), name)
assert db.execute('SELECT count(*) FROM flags').fetchone()[0] == 1
print('Named CHECK SQLite INSERT/UPDATE runtime checks passed')
