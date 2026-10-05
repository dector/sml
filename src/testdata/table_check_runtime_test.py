"""Run with python3 src/testdata/table_check_runtime_test.py (SQLite STRICT required)."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/table_checks.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)


def execute(statement, values, valid):
    try:
        db.execute(statement, values)
    except sqlite3.IntegrityError:
        assert not valid, (statement, values)
    else:
        assert valid, (statement, values)


insert = 'INSERT INTO ranges VALUES (1, ?, ?, ?)'
# Nullable comparisons permit UNKNOWN. Explicit null checks and field checks coexist.
for key, lower, upper, valid in [
    (1, 1, 9, True), (2, None, None, True), (3, None, 9, True),
    (4, 3, 2, False), (5, 1, None, False), (6, -1, 9, False),
    (7, 1, 100, False),
]:
    execute(insert, (key, lower, upper), valid)
execute(insert, (1, 1, 9), False)  # Composite key remains enforced.
update = 'UPDATE ranges SET "low""value" = ?, "high value" = ? WHERE entry_id = 1'
for lower, upper, valid in [(2, 8, True), (9, 8, False), (1, None, False),
                            (None, None, True), (-1, 8, False), (1, 100, False)]:
    execute(update, (lower, upper), valid)
for value, valid in [(None, True), (1, True), (0, False), (2, False)]:
    execute('INSERT INTO flags VALUES (?)', (value,), valid)
db.execute('INSERT INTO flags VALUES (1)')
execute('UPDATE flags SET enabled = ?', (0,), False)
execute('UPDATE flags SET enabled = ?', (None,), True)
start = '2024-01-01T00:00:00Z'
finish = '2024-01-02T00:00:00Z'
for left, right, valid in [(start, finish, True), (finish, start, False),
                           (start, None, True), (None, finish, True),
                           (start, '2024-01-02T01:00:00+01:00', False)]:
    execute('INSERT INTO times VALUES (?, ?)', (left, right), valid)
execute('UPDATE times SET start = ?, finish = ?', (finish, start), False)
execute('UPDATE times SET start = ?, finish = ?', (start, finish), True)
print('Table CHECK SQLite runtime checks passed')
