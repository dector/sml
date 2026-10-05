"""SQLite runtime checks for source-to-SQL single-field UNIQUE fixtures."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/unique.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)


def execute(statement, args, valid):
    try:
        db.execute(statement, args)
    except sqlite3.IntegrityError:
        assert not valid, (statement, args)
    else:
        assert valid, (statement, args)


columns = ['exact code', 'number', 'flag', 'created', 'choice', 'payload', 'ratio', 'raw']
insert = 'INSERT INTO "unique values" VALUES (' + ','.join('?' * 8) + ')'
# SQLite UNIQUE treats NULLs as distinct, including nullable NULL defaults.
execute(insert, [None] * 8, True)
execute(insert, [None] * 8, True)
values = ['x', 10, 1, '2024-01-01T00:00:00Z', 'a', b'x', 1.5, 'raw']
for i, value in enumerate(values):
    row = [None] * 8
    row[i] = value
    execute(insert, row, True)
    execute(insert, row, False)
    execute(f'UPDATE "unique values" SET "{columns[i]}" = ? WHERE rowid = 1', [value], False)
# Type and builtin CHECK validation remain enforced.
for i, value in [(0, 'bad'), (1, 'text'), (2, 2), (3, 'not a date'),
                 (4, 'c'), (5, 'text'), (6, 'text')]:
    row = [None] * 8
    row[i] = value
    execute(insert, row, False)
# Defaults do not bypass uniqueness. Raw SQL defaults do not bypass it either.
db.execute('DELETE FROM "unique values"')
execute('INSERT INTO "unique values" DEFAULT VALUES', [], True)
execute('INSERT INTO "unique values" DEFAULT VALUES', [], False)
db.execute('DELETE FROM "unique values"')
execute('INSERT INTO "unique values" ("exact code") VALUES (?)', ['a'], True)
execute('INSERT INTO "unique values" ("exact code") VALUES (?)', ['b'], False)
# Constraint names are local labels, not schema-wide index/object names.
db.execute('CREATE TABLE other (v TEXT CONSTRAINT "code""constraint" UNIQUE) STRICT')
db.execute('CREATE INDEX "code""constraint" ON other(v)')
print('Single-field UNIQUE SQLite runtime checks passed')
