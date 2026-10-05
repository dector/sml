"""Run emitted ordinary indexes in SQLite; inspect order, names and query plans."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/index.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
rows = db.execute('PRAGMA index_list("record"" store")').fetchall()
ordinary = {row[1]: row for row in rows if row[3] == 'c'}
assert set(ordinary) == {'first" lookup', 'record" store_first_idx',
                         'record" store_second value_idx',
                         'record" store_second value_first_idx', 'alternate'}
assert all(row[2] == 0 and row[4] == 0 for row in ordinary.values())
for name in ordinary:
    quoted = '"' + name.replace('"', '""') + '"'
    columns = [row[2] for row in db.execute(f'PRAGMA index_info({quoted})')]
    assert columns == (['second value', 'first'] if name in
                       ('alternate', 'record" store_second value_first_idx') else
                       ['second value'] if name == 'record" store_second value_idx' else ['first'])
assert [r[2] for r in db.execute('PRAGMA index_info("other_value_idx")')] == ['value']
# This table has no competing unique constraints or indexes, so the optimizer
# reliably chooses its single ordinary index for an equality lookup.
db.executemany('INSERT INTO other VALUES (?)', [(i % 100,) for i in range(1000)])
plan = db.execute('EXPLAIN QUERY PLAN SELECT * FROM other WHERE value = 42').fetchall()
assert any('other_value_idx' in r[3] and 'SEARCH' in r[3] for r in plan), plan
assert db.execute('SELECT count(*) FROM other WHERE value = 42').fetchone()[0] == 10
print('ordinary index runtime checks passed')
