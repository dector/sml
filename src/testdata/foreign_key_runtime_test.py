"""Stored FK enforcement requires PRAGMA on each connection, before a transaction."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/foreign_keys.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.execute('PRAGMA foreign_keys = ON')
assert db.execute('PRAGMA foreign_keys').fetchone() == (1,)
db.executescript(sql)


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement}')


# Defaults reference real parent rows, not merely values in the inherited domain.
rejected('INSERT INTO child DEFAULT VALUES')
db.execute('INSERT INTO "Parent Exact" VALUES (7)')
db.execute("INSERT INTO label VALUES ('seed')")
db.execute("INSERT INTO state VALUES ('ready')")
db.execute("INSERT INTO clock VALUES ('2000-02-29T00:00:00Z')")
db.execute('INSERT INTO child DEFAULT VALUES')
db.execute('INSERT INTO child VALUES (NULL, NULL, NULL, NULL)')
for column, value in [('Owner Exact', '8'), ('label', "'missing'"),
                      ('state', "'done'"), ('stamp', "'2001-01-01T00:00:00Z'")]:
    rejected(f'INSERT INTO child ("{column}") VALUES ({value})')
rejected('INSERT INTO child DEFAULT VALUES')  # local UNIQUE remains effective
rejected('INSERT INTO child ("Owner Exact") VALUES (-1)')  # CHECK remains effective
for table, column, value in [('Parent Exact', 'Key Exact', '8'),
                              ('label', 'key', "'new'"),
                              ('state', 'key', "'done'"),
                              ('clock', 'key', "'2001-01-01T00:00:00Z'")]:
    rejected(f'DELETE FROM "{table}"')
    rejected(f'UPDATE "{table}" SET "{column}" = {value}')
rows = list(db.execute('PRAGMA foreign_key_list(child)'))
assert len(rows) == 4
assert all(r[5] == 'NO ACTION' and r[6] == 'RESTRICT' for r in rows)
assert {r[1] for r in db.execute('PRAGMA index_list(child)')} == {
    'child_label_idx', 'sqlite_autoindex_child_1'}
for table in ['node', 'left', 'right']:
    assert not list(db.execute(f'PRAGMA index_list("{table}")'))
# Same-row self references and cycles formed using existing parent keys are valid.
db.execute('INSERT INTO node VALUES (1, 1)')
db.execute('INSERT INTO node VALUES (2, 1)')
db.execute('UPDATE node SET parent = 2 WHERE id = 1')
rejected('DELETE FROM node WHERE id = 1')
rejected('INSERT INTO node VALUES (3, 99)')
db.execute('INSERT INTO "left" VALUES (1, NULL)')
db.execute('INSERT INTO "right" VALUES (1, 1)')
db.execute('UPDATE "left" SET "right" = 1')
rejected('DELETE FROM "right"')
assert not list(db.execute('PRAGMA foreign_key_check'))
print('foreign key runtime checks passed')
