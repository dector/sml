"""Execute generated table uniqueness against SQLite, including updates and NULLs."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/composite_unique.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
assert len(db.execute('PRAGMA table_info("pairs")').fetchall()) == 5

def execute(statement, values, succeeds=True):
    try:
        db.execute(statement, values)
    except sqlite3.IntegrityError:
        assert not succeeds, (statement, values)
    else:
        assert succeeds, (statement, values)

insert = 'INSERT INTO "pairs" VALUES (?, ?, ?, ?, ?)'
execute(insert, (1, 1, 'a', 'x', None))
execute(insert, (2, 1, 'a', 'y', None))  # Same left is allowed.
execute(insert, (3, 1, 'b', 'x', None))  # Same right is allowed.
execute(insert, (4, 1, 'a', 'x', None), False)  # Duplicate pair.
execute('UPDATE "pairs" SET "right""value" = ? WHERE key_a = 2', ('x',), False)
execute('UPDATE "pairs" SET "right""value" = ? WHERE key_a = 2', ('z',))
# Any NULL component makes pairs distinct, including two NULL components.
for key, left, right in [(4, None, 'x'), (5, None, 'x'), (6, 'a', None),
                         (7, 'a', None), (8, None, None), (9, None, None)]:
    execute(insert, (key, 1, left, right, None))
execute(insert, (10, 1, 'c', 'q', True))
execute(insert, (11, 1, 'd', 'r', True), False)  # Boolean single table UNIQUE.
execute(insert, (11, 1, 'd', 'r', False))
execute('INSERT INTO other VALUES (?, ?)', (1, 2))
execute('INSERT INTO other VALUES (?, ?)', (1, 3))
execute('INSERT INTO other VALUES (?, ?)', (1, 2), False)
print('composite uniqueness runtime checks passed')
