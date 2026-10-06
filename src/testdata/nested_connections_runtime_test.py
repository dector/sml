"""Nested endpoints reference complete connection tuples, not independent leaves."""
import pathlib
import sqlite3
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
subprocess.run(['zig', 'build'], cwd=ROOT, check=True)
fixture = ROOT / 'src/testdata/parser/nested_connections.sml'
result = subprocess.run([str(ROOT / 'zig-out/bin/sml'), str(fixture)],
                        capture_output=True, text=True, check=True)
assert result.stdout == fixture.with_suffix('.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.execute('PRAGMA foreign_keys = ON')
db.executescript(result.stdout)
assert db.execute('PRAGMA foreign_keys').fetchone() == (1,)


def rejected(statement, parameters=()):
    try:
        db.execute(statement, parameters)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement} {parameters}')


for table, keys in [
    ('authorship', ('author_id', 'book_id')),
    ('credit', ('authorship_author_id', 'authorship_book_id', 'organization_id')),
    ('explicit_credit', ('pair_author_id', 'pair_book_id', 'organization_id')),
    ('cascade_credit', ('authorship_author_id', 'authorship_book_id', 'organization_id')),
    ('tuple_cascade_credit', ('pair_author_id', 'pair_book_id', 'organization_id')),
    ('approval', ('credit_authorship_author_id', 'credit_authorship_book_id',
                  'credit_organization_id', 'reviewer_id')),
    ('authorship__n__reviewer', ('authorship_author_id', 'authorship_book_id', 'reviewer_id')),
]:
    info = list(db.execute(f'PRAGMA table_info("{table}")'))
    assert tuple(r[1] for r in sorted(info, key=lambda r: r[5]) if r[5]) == keys
    assert all(r[3] == 1 and r[4] is None for r in info if r[5])
    if table != 'authorship':
        parent = 'credit' if table == 'approval' else 'authorship'
        target_keys = ('authorship_author_id', 'authorship_book_id', 'organization_id') \
            if table == 'approval' else ('author_id', 'book_id')
        foreign_keys = [r for r in db.execute(f'PRAGMA foreign_key_list("{table}")')
                        if r[2] == parent]
        foreign_keys.sort(key=lambda r: r[1])
        assert len({r[0] for r in foreign_keys}) == 1  # One composite FK.
        assert tuple(r[3] for r in foreign_keys) == keys[:len(target_keys)]
        assert tuple(r[4] for r in foreign_keys) == target_keys
        action = 'CASCADE' if 'cascade' in table else 'RESTRICT'
        assert all(r[6] == action for r in foreign_keys)

# Both leaf rows exist, but only one of their pairings exists.
db.execute('INSERT INTO author VALUES (1), (2)')
db.execute('INSERT INTO book VALUES (10), (20)')
db.execute('INSERT INTO organization VALUES (100), (200)')
db.execute('INSERT INTO reviewer VALUES (7)')
db.execute('INSERT INTO authorship VALUES (1, 10)')
for table in ['credit', 'explicit_credit', 'cascade_credit', 'tuple_cascade_credit']:
    insert = f'INSERT INTO "{table}" VALUES (?, ?, ?)'
    rejected(insert, (1, 20, 100))  # Not a real Authorship, despite valid leaves.
    rejected(insert, (2, 10, 100))
    db.execute(insert, (1, 10, 100))
    rejected(insert, (1, 10, 100))  # Tuple PK uniqueness.
    for values in [(None, 10, 100), (1, None, 100), (1, 10, None)]:
        rejected(insert, values)
    rejected(f'INSERT INTO "{table}" DEFAULT VALUES')  # No inherited autogen.
    book_column = 'pair_book_id' if table in ['explicit_credit', 'tuple_cascade_credit'] \
        else 'authorship_book_id'
    rejected(f'UPDATE "{table}" SET "{book_column}" = 20')
    assert db.execute(f'SELECT * FROM "{table}"').fetchone() == (1, 10, 100)

db.execute('INSERT INTO authorship__n__reviewer VALUES (1, 10, 7)')
rejected('INSERT INTO authorship__n__reviewer VALUES (1, 20, 7)')
db.execute('INSERT INTO approval VALUES (1, 10, 100, 7)')
# The Authorship and Organization exist, but their Credit tuple does not.
rejected('INSERT INTO approval VALUES (1, 10, 200, 7)')
rejected('UPDATE approval SET credit_organization_id = 200')
rejected('DELETE FROM credit')  # Deeper endpoint restriction.
db.execute('DELETE FROM approval')
rejected('DELETE FROM authorship')
rejected('DELETE FROM author WHERE id = 1')
assert db.execute('SELECT count(*) FROM authorship').fetchone() == (1,)
# Remove restrictive references; both component overrides and tuple policy cascade.
db.execute('DELETE FROM credit')
db.execute('DELETE FROM explicit_credit')
db.execute('DELETE FROM authorship__n__reviewer')
db.execute('DELETE FROM authorship')
assert db.execute('SELECT count(*) FROM cascade_credit').fetchone() == (0,)
assert db.execute('SELECT count(*) FROM tuple_cascade_credit').fetchone() == (0,)
assert db.execute('SELECT count(*) FROM author').fetchone() == (2,)
assert db.execute('SELECT count(*) FROM book').fetchone() == (2,)
assert not list(db.execute('PRAGMA foreign_key_check'))
print('nested connection runtime checks passed')
