"""Shared keys require existing explicit identity, not SQLite rowid generation."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/shared_identity.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
assert db.execute('PRAGMA foreign_keys').fetchone() == (1,)


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement}')


for table in ['shared', 'chain']:
    rejected(f'INSERT INTO {table} DEFAULT VALUES')
    rejected(f'INSERT INTO {table} VALUES (NULL)')
    rejected(f'INSERT INTO {table} VALUES (7)')
rejected('INSERT INTO default_shared DEFAULT VALUES')
db.execute('INSERT INTO "Identity Exact" VALUES (7)')
db.execute('INSERT INTO shared VALUES (7)')
db.execute('INSERT INTO chain VALUES (7)')
db.execute('INSERT INTO default_shared DEFAULT VALUES')
for table in ['shared', 'chain', 'default_shared']:
    rejected(f'INSERT INTO {table} VALUES (7)')
    rejected(f'INSERT INTO {table} VALUES (NULL)')
    rejected(f'INSERT INTO {table} VALUES (99)')
assert sql.count('WITHOUT ROWID') == 3
assert sql.count('AUTOINCREMENT') == 1
# The ordinary integer parent still generates IDs for omitted and explicit NULL.
db.execute('INSERT INTO "Identity Exact" DEFAULT VALUES')
db.execute('INSERT INTO "Identity Exact" VALUES (NULL)')
assert list(db.execute('SELECT * FROM "Identity Exact"')) == [(7,), (8,), (9,)]
# A composite key does not require WITHOUT ROWID, but every key part is NOT NULL.
db.execute('INSERT INTO tuple VALUES (7, 1)')
db.execute('INSERT INTO tuple VALUES (7, 2)')
for values in ['7, 1', 'NULL, 1', '7, NULL', '99, 1']:
    rejected(f'INSERT INTO tuple VALUES ({values})')
for prefix, value in [('text', "'seed'"), ('enum', "'ready'"),
                      ('time', "'2000-02-29T00:00:00Z'")]:
    rejected(f'INSERT INTO {prefix}_shared DEFAULT VALUES')
    db.execute(f'INSERT INTO {prefix}_identity VALUES ({value})')
    db.execute(f'INSERT INTO {prefix}_shared DEFAULT VALUES')
    rejected(f'INSERT INTO {prefix}_shared VALUES (NULL)')
    rejected(f'INSERT INTO {prefix}_shared VALUES ({value})')
    db.execute(f'DELETE FROM {prefix}_shared')
# A noninteger shared key without a default also requires explicit identity.
rejected('INSERT INTO text_required DEFAULT VALUES')
rejected('INSERT INTO text_required VALUES (NULL)')
rejected("INSERT INTO text_required VALUES ('missing')")
db.execute("INSERT INTO text_required VALUES ('seed')")
rejected("INSERT INTO text_required VALUES ('seed')")
# RESTRICT dependents must go first, then cascade travels through a shared PK.
db.execute('DELETE FROM default_shared')
db.execute('DELETE FROM tuple')
db.execute('DELETE FROM "Identity Exact" WHERE "Key Exact" = 7')
assert not list(db.execute('SELECT * FROM shared'))
assert not list(db.execute('SELECT * FROM chain'))
assert not list(db.execute('PRAGMA foreign_key_check'))
print('shared identity runtime checks passed')
