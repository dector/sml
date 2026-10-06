"""Automatic FK indexes: full leading coverage, partial exclusion, no duplicates."""
import pathlib
import sqlite3

db = sqlite3.connect(':memory:')
db.executescript((pathlib.Path(__file__).parent / 'parser/foreign_key_indexes.expect.sql').read_text())
rows = {r[1]: r for r in db.execute('PRAGMA index_list(child)')}
explicit = {
    'child_tail_second_idx': (0, 0, ['tail', 'second']),
    'child_ordinary_tail_idx': (0, 0, ['ordinary', 'tail']),
    'child_unique_index_tail_idx': (1, 0, ['unique_index', 'tail']),
    'partial lookup': (0, 1, ['partial']),
    'partial unique lookup': (1, 1, ['partial_unique']),
    'true lookup': (0, 1, ['truth']),
}
for column in ['second', 'partial', 'partial_unique', 'truth']:
    explicit[f'child_{column}_idx'] = (0, 0, [column])
assert len(rows) == 13  # ten CREATE indexes and three native constraints
assert {name for name, row in rows.items() if row[3] == 'c'} == set(explicit)
for name, (unique, partial, columns) in explicit.items():
    assert rows[name][2] == unique and rows[name][4] == partial
    assert [r[2] for r in db.execute(f'PRAGMA index_info("{name}")')] == columns
# Each FK has a full leading index, including nullable UNIQUE constraints.
leading = set()
for name, row in rows.items():
    if not row[4]:
        leading.add(next(db.execute(f'PRAGMA index_info("{name}")'))[2])
assert leading == {'first', 'second', 'native', 'composite', 'tail', 'ordinary',
                   'unique_index', 'partial', 'partial_unique', 'truth'}
assert len(list(db.execute('PRAGMA index_list(shared)'))) == 1  # PK only
assert not list(db.execute('PRAGMA index_list(parent)'))  # rowid PK
assert len(list(db.execute('PRAGMA index_list(rowid)'))) == 1  # UNIQUE only
# The second PK column and the constant-true partial index cannot substitute.
for column in ['second', 'truth']:
    plan = ' '.join(r[3] for r in db.execute(
        f'EXPLAIN QUERY PLAN SELECT rowid FROM child WHERE "{column}" = ?', (1,)))
    assert f'child_{column}_idx' in plan, plan
# Generated indexes must not impose uniqueness, including partial-unique NULLs.
db.execute('INSERT INTO parent VALUES (1)')
db.execute('INSERT INTO parent VALUES (2)')
db.execute('INSERT INTO child(first, second, partial_unique) VALUES (1, 1, NULL)')
db.execute('INSERT INTO child(first, second, partial_unique) VALUES (2, 1, NULL)')
assert db.execute('SELECT count(*) FROM child WHERE second = 1').fetchone()[0] == 2
print('automatic FK index runtime checks passed')
