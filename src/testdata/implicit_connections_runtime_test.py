"""Implicit generated tuple keys are required, unique and restrictive."""
import pathlib
import sqlite3

sql = (pathlib.Path(__file__).parent / 'parser/implicit_connections.expect.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript(sql)
db.execute('INSERT INTO writers DEFAULT VALUES')
db.execute('INSERT INTO writers DEFAULT VALUES')
db.execute('INSERT INTO book DEFAULT VALUES')
assert db.execute('SELECT book_id FROM author__n__book WHERE author_id = 2').fetchall() == []
db.execute('INSERT INTO author__n__book (author_id, book_id) VALUES (1, 1)')
for statement in (
    'INSERT INTO author__n__book (author_id, book_id) VALUES (1, 1)',
    'INSERT INTO author__n__book DEFAULT VALUES',
    'INSERT INTO author__n__book (author_id) VALUES (1)',
    'INSERT INTO author__n__book (book_id) VALUES (1)',
    'INSERT INTO author__n__book (author_id, book_id) VALUES (NULL, 1)',
    'INSERT INTO author__n__book (author_id, book_id) VALUES (1, NULL)',
    'INSERT INTO author__n__book (author_id, book_id) VALUES (99, 1)',
    'DELETE FROM writers WHERE writer_key = 1',
    'DELETE FROM book WHERE id = 1',
):
    try:
        db.execute(statement)
    except sqlite3.IntegrityError:
        pass
    else:
        raise AssertionError(statement)
plan = db.execute('EXPLAIN QUERY PLAN SELECT author_id FROM author__n__book WHERE book_id = 1').fetchall()
assert any('author__n__book_book_id_idx' in row[3] for row in plan), plan
assert db.execute('PRAGMA foreign_key_check').fetchall() == []
print('implicit connection runtime checks passed')
