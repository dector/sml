"""Run emitted unique indexes: metadata, distinct NULLs, INSERT and UPDATE."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/unique_index.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
expected = {
    'record store': {
        'first lookup': (1, ['first']),
        'record store_b_idx': (0, ['b']),
        'single b': (1, ['b']),
        'pair lookup': (1, ['c', 'b']),
        'record store_c_b_idx': (0, ['c', 'b']),
    },
    'pair': {'pair_b_a_idx': (1, ['b', 'a'])},
    'other': {'other_value_idx': (1, ['value'])},
}
for table, indexes in expected.items():
    rows = {r[1]: r for r in db.execute(f'PRAGMA index_list("{table}")') if r[3] == 'c'}
    assert set(rows) == set(indexes)
    for name, (unique, columns) in indexes.items():
        assert rows[name][2] == unique and rows[name][4] == 0
        assert [r[2] for r in db.execute(f'PRAGMA index_info("{name}")')] == columns


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted duplicate: {statement}')


# Field unique index and native constraint coexist, even with the same label.
db.executemany('INSERT INTO "record store" VALUES (?, ?, ?)',
               [(1, 10, 100), (2, 20, 200), (None, None, None), (None, None, None)])
rejected('INSERT INTO "record store" VALUES (3, 10, 300)')  # table singleton
rejected('UPDATE "record store" SET b = 10 WHERE first = 2')
# Isolated field index verifies enforcement without a native UNIQUE constraint.
db.executemany('INSERT INTO other VALUES (?)', [(1,), (2,), (None,), (None,)])
rejected('INSERT INTO other VALUES (1)')
rejected('UPDATE other SET value = 1 WHERE value = 2')
db.executemany('INSERT INTO pair VALUES (?, ?)',
               [(1, 2), (1, 3), (2, 2), (None, 2), (None, 2),
                (1, None), (1, None), (None, None), (None, None)])
rejected('INSERT INTO pair VALUES (1, 2)')
rejected('UPDATE pair SET b = 2 WHERE a = 1 AND b = 3')
print('unique index runtime checks passed')
