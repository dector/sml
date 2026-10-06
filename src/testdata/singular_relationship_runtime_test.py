"""Cardinality comes from existing SQLite keys, not virtual relationship SQL."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/singular_relationships.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
db.execute('INSERT INTO owner VALUES (7)')


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement}')


for table in ['field_profile', 'table_profile', 'index_profile', 'shared_profile']:
    db.execute(f'INSERT INTO {table} VALUES (7)')
    rejected(f'INSERT INTO {table} VALUES (7)')
    rejected(f'INSERT INTO {table} VALUES (99)')
    if table == 'shared_profile':
        rejected(f'INSERT INTO {table} VALUES (NULL)')
    else:
        # NULL never references an owner; multiple NULLs do not affect cardinality.
        db.execute(f'INSERT INTO {table} VALUES (NULL)')
        db.execute(f'INSERT INTO {table} VALUES (NULL)')
assert not list(db.execute('PRAGMA foreign_key_check'))
print('singular relationship runtime checks passed')
