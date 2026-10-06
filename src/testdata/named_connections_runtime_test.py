"""Explicit connection tables retain ordinary SQLite FK/PK/payload behavior."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/named_connections.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.execute('PRAGMA foreign_keys = ON')
db.executescript(sql)
assert db.execute('PRAGMA foreign_keys').fetchone() == (1,)
assert [r[0] for r in db.execute("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name")] == [
    'Books Exact', 'Borrow Exact', 'People Exact', 'Triple Exact']


def rejected(statement, parameters=()):
    try:
        db.execute(statement, parameters)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement} {parameters}')


def indexes(table):
    return [(r[1], r[3], tuple(c[2] for c in db.execute(f'PRAGMA index_info("{r[1]}")')))
            for r in db.execute(f'PRAGMA index_list("{table}")')]


# Only a leading key covers reverse FK lookups. Header order never changes PK order.
for table, primary, additional in [
    ('Borrow Exact', ('Book Ref', 'Person Ref'), {
        ('Borrow Exact_Person Ref_idx', 'c', ('Person Ref',)),
        ('State Lookup', 'c', ('state',)),
    }),
    ('Triple Exact', ('Context Ref', 'Destination Ref', 'Origin Ref'), {
        ('Triple Exact_Destination Ref_idx', 'c', ('Destination Ref',)),
        ('Triple Exact_Origin Ref_idx', 'c', ('Origin Ref',)),
    }),
]:
    info = list(db.execute(f'PRAGMA table_info("{table}")'))
    assert tuple(r[1] for r in sorted(info, key=lambda r: r[5]) if r[5]) == primary
    assert all(r[3] == 1 for r in info if r[5])  # No nullable endpoint keys.
    actual = indexes(table)
    assert [columns for _, origin, columns in actual if origin == 'pk'] == [primary]
    assert set(i for i in actual if i[1] == 'c') == additional
    assert all(columns != (primary[0],) for _, origin, columns in actual if origin == 'c')
assert [columns for _, origin, columns in indexes('Borrow Exact') if origin == 'u'] == [('tag',)]

# Real parent values are inherited; nothing generates or prefills endpoint keys.
db.execute('INSERT INTO "People Exact" VALUES (1.5), (2.5), (3.5), (4.5), (9.5)')
db.execute('INSERT INTO "Books Exact" VALUES (\'a\'), (\'b\')')
insert = 'INSERT INTO "Borrow Exact" ("Book Ref", "Person Ref", tag) VALUES (?, ?, ?)'
db.execute(insert, ('a', 1.5, 'first'))
db.execute(insert, ('a', 2.5, 'survivor'))
db.execute(insert, ('b', 1.5, 'second'))
assert db.execute('SELECT amount, state, created_at FROM "Borrow Exact" WHERE tag=\'first\'').fetchone() == (
    2, 'ready', '2000-02-29T00:00:00Z')
rejected(insert, ('a', 1.5, 'duplicate tuple'))
rejected(insert, ('b', 2.5, 'first'))  # Payload UNIQUE.
rejected(insert, ('missing', 9.5, 'bad book'))
rejected(insert, ('a', 99.5, 'bad person'))
rejected(insert, (None, 9.5, 'null book'))
rejected(insert, ('a', None, 'null person'))
rejected('INSERT INTO "Borrow Exact" ("Person Ref", tag) VALUES (9.5, \'omitted book\')')
rejected('INSERT INTO "Borrow Exact" ("Book Ref", tag) VALUES (\'a\', \'omitted person\')')
for column, value in [('amount', 0), ('amount', 10), ('amount', 'text'),
                      ('state', 'unknown'), ('state', None),
                      ('created_at', '2001-02-29T00:00:00Z'),
                      ('created_at', '2000-02-29'), ('created_at', None)]:
    rejected(f'INSERT INTO "Borrow Exact" ("Book Ref", "Person Ref", tag, "{column}") VALUES (?, ?, ?, ?)',
             ('b', 9.5, 'invalid payload', value))
db.execute('INSERT INTO "Borrow Exact" ("Book Ref", "Person Ref", tag, amount, state, created_at) '
           'VALUES (\'b\', 9.5, \'valid payload\', 9, \'done\', \'2024-02-29T23:59:59Z\')')

triple = 'INSERT INTO "Triple Exact" ("Context Ref", "Destination Ref", "Origin Ref") VALUES (?, ?, ?)'
db.execute(triple, (3.5, 2.5, 4.5))
db.execute(triple, (9.5, 2.5, 4.5))  # Same mapped pair, different third endpoint.
rejected(triple, (3.5, 2.5, 4.5))
for values in [(None, 2.5, 4.5), (3.5, None, 4.5), (3.5, 2.5, None),
               (99.5, 2.5, 4.5), (3.5, 99.5, 4.5), (3.5, 2.5, 99.5)]:
    rejected(triple, values)
for column in ['Context Ref', 'Destination Ref', 'Origin Ref']:
    others = [c for c in ['Context Ref', 'Destination Ref', 'Origin Ref'] if c != column]
    rejected(f'INSERT INTO "Triple Exact" ("{others[0]}", "{others[1]}") VALUES (3.5, 4.5)')
assert list(db.execute('SELECT "Destination Ref" FROM "Triple Exact" WHERE "Origin Ref"=4.5')) == [(2.5,), (2.5,)]
assert list(db.execute('SELECT note FROM "Triple Exact"')) == [('seed',), ('seed',)]

# Custom parent SQL names and explicit FK policies control deletion, not roles.
rejected('DELETE FROM "Books Exact" WHERE "Book Key"=\'a\'')
db.execute('DELETE FROM "People Exact" WHERE "Person Key"=1.5')
assert list(db.execute('SELECT tag FROM "Borrow Exact" ORDER BY tag')) == [('survivor',), ('valid payload',)]
assert db.execute('SELECT count(*) FROM "Triple Exact"').fetchone() == (2,)
rejected('DELETE FROM "People Exact" WHERE "Person Key"=2.5')
# A failed RESTRICT delete must also undo any cascade work in the same statement.
assert db.execute('SELECT count(*) FROM "Borrow Exact" WHERE tag=\'survivor\'').fetchone() == (1,)
assert db.execute('SELECT count(*) FROM "People Exact" WHERE "Person Key"=2.5').fetchone() == (1,)
assert not list(db.execute('PRAGMA foreign_key_check'))
print('named connection runtime checks passed')
