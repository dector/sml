"""Generated keys behave exactly like explicitly written SQLite PK/FKs."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/generated_connections.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.execute('PRAGMA foreign_keys = ON')
db.executescript(sql)


def rejected(statement, parameters=()):
    try:
        db.execute(statement, parameters)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement} {parameters}')


for table, keys, additional in [
    ('pair', ('writer_account_key', 'snake_name_account_key'), {'snake_name_account_key', 'cleanup'}),
    ('trio', ('left_account_key', 'right_account_key', 'context_account_key'), {'right_account_key', 'context_account_key'}),
    ('kinds', ('state_state_key', 'clock_moment', 'alias_external_key'), {'clock_moment', 'alias_external_key'}),
]:
    info = list(db.execute(f'PRAGMA table_info("{table}")'))
    assert tuple(r[1] for r in info[:len(keys)]) == keys
    assert tuple(r[1] for r in sorted(info, key=lambda r: r[5]) if r[5]) == keys
    assert all(r[3] == 1 and r[4] is None for r in info[:len(keys)])
    columns = []
    for index in db.execute(f'PRAGMA index_list("{table}")'):
        if index[3] == 'c':
            columns.append(tuple(r[2] for r in db.execute(f'PRAGMA index_info("{index[1]}")')))
    assert set(columns) == {(name,) for name in additional}

db.execute('INSERT INTO "Author Exact" VALUES (1), (2), (3), (9)')
db.execute("INSERT INTO snake_name VALUES ('a'), ('b')")
pair = 'INSERT INTO pair(writer_account_key, snake_name_account_key) VALUES (?, ?)'
db.execute(pair, (1, 'a'))
db.execute(pair, (2, 'a'))
assert db.execute('SELECT amount, cleanup FROM pair WHERE writer_account_key=1').fetchone() == (2, None)
rejected(pair, (1, 'a'))
for values in [(None, 'b'), (3, None), (99, 'b'), (3, 'missing')]:
    rejected(pair, values)
rejected("INSERT INTO pair(snake_name_account_key) VALUES ('b')")
rejected('INSERT INTO pair(writer_account_key) VALUES (3)')
rejected('DELETE FROM "Author Exact" WHERE "Actual Key"=1')
rejected("DELETE FROM snake_name WHERE account_key='a'")
# Payload FKs retain ordinary cascade behavior; generated keys default to RESTRICT.
db.execute("INSERT INTO pair VALUES (3, 'b', 2, 9)")
db.execute('DELETE FROM "Author Exact" WHERE "Actual Key"=9')
assert db.execute('SELECT count(*) FROM pair WHERE writer_account_key=3').fetchone() == (0,)
trio = 'INSERT INTO trio(left_account_key, right_account_key, context_account_key) VALUES (?, ?, ?)'
db.execute(trio, (1, 2, 3))
db.execute(trio, (1, 2, 1))  # Same pair, different third endpoint.
rejected(trio, (1, 2, 3))
assert db.execute('SELECT label FROM trio LIMIT 1').fetchone() == ('ready',)
rejected('INSERT INTO trio(left_account_key, right_account_key) VALUES (1, 2)')
rejected(trio, (1, 2, None))
rejected('DELETE FROM "Author Exact" WHERE "Actual Key"=3')
db.execute("INSERT INTO state VALUES ('ready')")
db.execute("INSERT INTO clock VALUES ('2000-02-29T00:00:00Z')")
db.execute('INSERT INTO alias VALUES (1)')
kinds = 'INSERT INTO kinds VALUES (?, ?, ?)'
db.execute(kinds, ('ready', '2000-02-29T00:00:00Z', 1))
rejected(kinds, ('unknown', '2000-02-29T00:00:00Z', 1))
rejected(kinds, ('ready', '2000-02-30T00:00:00Z', 1))
rejected(kinds, ('ready', '2000-02-29T00:00:00Z', 2))
rejected('INSERT INTO kinds(clock_moment, alias_external_key) VALUES (?, ?)', ('2000-02-29T00:00:00Z', 1))
print('generated connection runtime tests passed')
