"""Execute SQL whose complete output is checked by extended_unnamed_test.zig."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/extended_unnamed.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(statement)


for table in ['Parent', 'b', 'c']:
    db.execute(f'INSERT INTO "{table}" VALUES (1), (2), (3)')
db.execute('INSERT INTO a__n__b__n__c(b_key, c_key) VALUES (1, 1), (1, 2)')
assert db.execute('SELECT a_key FROM a__n__b__n__c').fetchall() == [(1,), (1,)]
rejected('INSERT INTO a__n__b__n__c VALUES (1, 1, 1)')
rejected('INSERT INTO a__n__b__n__c VALUES (1, 1, 99)')
rejected('INSERT INTO a__n__b__n__c VALUES (NULL, 1, 3)')
rejected('DELETE FROM b WHERE key=1')  # Default RESTRICT.
rejected('DELETE FROM c WHERE key=1')
db.execute('DELETE FROM "Parent" WHERE key=1')  # Overridden CASCADE.
assert db.execute('SELECT count(*) FROM a__n__b__n__c').fetchone() == (0,)
db.execute('INSERT INTO a__n__a VALUES (2, 3), (3, 2), (2, 2)')
rejected('INSERT INTO a__n__a VALUES (2, 3)')
rejected('INSERT INTO a__n__a VALUES (2, 99)')
rejected('DELETE FROM "Parent" WHERE key=3')
db.execute('INSERT INTO a__n__a__n__b VALUES (2, 3, 1), (2, 3, 2)')
rejected('INSERT INTO a__n__a__n__b VALUES (2, 3, 1)')

for table, keys in [
    ('a__n__b__n__c', ('a_key', 'b_key', 'c_key')),
    ('a__n__a', ('left_key', 'right_key')),
    ('a__n__a__n__b', ('left_key', 'right_key', 'b_key')),
]:
    info = list(db.execute(f'PRAGMA table_info("{table}")'))
    assert tuple(row[1] for row in sorted(info, key=lambda r: r[5]) if row[5]) == keys
    indexes = [tuple(row[2] for row in db.execute(f'PRAGMA index_info("{index[1]}")'))
               for index in db.execute(f'PRAGMA index_list("{table}")')]
    assert all(any(columns[0] == key for columns in indexes) for key in keys)
assert db.execute('PRAGMA foreign_key_check').fetchall() == []
print('extended unnamed runtime checks passed')
