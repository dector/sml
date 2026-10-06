"""Direct relationships add no SQLite objects; backing FKs/UNIQUE do the work."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/direct_relationships.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
assert list(db.execute("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) == [('Items',), ('Nodes',), ('Owners',)]
for table, columns in [('Owners', ['Key', 'label']), ('Items', ['note', 'OwnerKey']), ('Nodes', ['id', 'parent'])]:
    assert [row[1] for row in db.execute(f'PRAGMA table_info("{table}")')] == columns
    # UNIQUE's real autoindex covers each FK, with no redundant generated index.
    indexes = list(db.execute(f'PRAGMA index_list("{table}")'))
    assert len(indexes) == (0 if table == 'Owners' else 1)
    assert all(row[3] == 'u' for row in indexes)
assert list(db.execute('PRAGMA foreign_key_list("Items")'))[0][2:5] == ('Owners', 'OwnerKey', 'Key')
assert list(db.execute('PRAGMA foreign_key_list("Nodes")'))[0][2:5] == ('Nodes', 'parent', 'id')


def rejected(statement):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        return
    raise AssertionError(f'accepted: {statement}')


db.execute("INSERT INTO Owners VALUES (7, 'owner')")
db.execute("INSERT INTO Items VALUES ('profile', 7)")
rejected("INSERT INTO Items VALUES ('duplicate', 7)")
rejected("INSERT INTO Items VALUES ('missing', 99)")
db.execute("INSERT INTO Items VALUES ('null', NULL), ('null again', NULL)")
db.execute('INSERT INTO Nodes VALUES (1, NULL), (2, 1)')
rejected('INSERT INTO Nodes VALUES (3, 1)')
rejected('INSERT INTO Nodes VALUES (3, 99)')
assert not list(db.execute('PRAGMA foreign_key_check'))
print('direct relationship runtime checks passed')
