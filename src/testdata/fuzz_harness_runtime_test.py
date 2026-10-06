"""Fast stdlib regression checks for the fuzz harness (no compiler required)."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import random
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fuzz_runtime_test as fuzz


class FuzzHarnessTests(unittest.TestCase):
    kinds = ('fixture-mutation-status-only', 'arbitrary-bytes-status-only',
             'literal-comment-mutation-status-only', 'generated-sql')

    def result(self, status, stdout=b'', stderr=b''):
        return subprocess.CompletedProcess(['fake-compiler'], status, stdout, stderr)

    def test_output_contract(self):
        for kind in self.kinds:
            for status, stdout, stderr, reason in (
                    (0, b'sql', b'error', 'successful compiler wrote stderr'),
                    (1, b'partial sql', b'error', 'rejected compiler wrote stdout'),
                    (1, b'partial sql', b'', 'rejected compiler wrote stdout'),
                    (1, b'', b'', 'rejected compiler wrote no diagnostic'),
                    (2, b'', b'error', 'unexpected compiler status 2'),
                    (-11, b'', b'', 'unexpected compiler status -11')):
                with self.subTest(kind=kind, status=status, stdout=stdout, stderr=stderr):
                    self.assertEqual(fuzz.validate_result(
                        kind, b'\xff', self.result(status, stdout, stderr)), reason)

    def test_status_only_byte_preservation(self):
        for kind in self.kinds[:-1]:
            self.assertIsNone(fuzz.validate_result(kind, b'\xff', self.result(0, b'\xff\0')))
            self.assertIsNone(fuzz.validate_result(kind, b'\xff', self.result(1, stderr=b'error')))

    def test_generated_rejection(self):
        self.assertEqual(fuzz.validate_result('generated-sql', b'', self.result(1, stderr=b'error')),
                         'known-valid generated DSL rejected')

    def test_generated_empty_or_unrelated_schema(self):
        source = fuzz.generated(random.Random(2))
        for sql in (b'', b'-- nothing\n', b'CREATE TABLE unrelated (id INTEGER);'):
            with self.subTest(sql=sql), self.assertRaisesRegex(ValueError, 'table_list mismatch'):
                fuzz.validate_result('generated-sql', source, self.result(0, sql))

    def valid_sql(self, source):
        import re
        owner, item = [s.decode() for s in re.findall(
            rb'^  #name `((?:owner|item) [^`]+)`$', source, re.MULTILINE)]
        quote = lambda s: '"' + s.replace('"', '""') + '"'
        sql = f'''CREATE TABLE {quote(owner)} (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT) STRICT;
CREATE TABLE {quote(item)} (id INTEGER PRIMARY KEY AUTOINCREMENT,
owner INTEGER REFERENCES {quote(owner)}(id), low INTEGER, high INTEGER,
enabled INTEGER, ratio REAL, note TEXT, day TEXT, moment TEXT, state TEXT) STRICT;
CREATE INDEX "owner lookup" ON {quote(item)}(owner);
CREATE INDEX "range lookup" ON {quote(item)}(low, high);
CREATE UNIQUE INDEX "note unique" ON {quote(item)}(note);
'''
        connection = 'pair' if b'~Pair(' in source else ('triple' if b'~Triple(' in source else None)
        if connection:
            sql += f'CREATE TABLE {connection} (a INTEGER, b INTEGER, c TEXT) STRICT;\n'
        return sql.encode()

    def test_generated_expected_table_shapes(self):
        # Cover no connection, Pair, Triple and SQL names requiring quoting.
        for seed in (0, 2, 4):
            source = fuzz.generated(random.Random(seed))
            self.assertIsNone(fuzz.validate_result('generated-sql', source,
                              self.result(0, self.valid_sql(source))))

    def test_generated_wrong_fk_or_indexes(self):
        source = fuzz.generated(random.Random(2))
        sql = self.valid_sql(source)
        for bad in (sql.replace(b'owner INTEGER REFERENCES', b'other_id INTEGER REFERENCES')
                    .replace(b'(owner)', b'(other_id)'),
                    sql.replace(b'"owner lookup"', b'"wrong index"')):
            with self.assertRaisesRegex(ValueError, 'shape mismatch|index names mismatch'):
                fuzz.validate_result('generated-sql', source, self.result(0, bad))

    def report(self, directory):
        output = io.StringIO()
        with redirect_stdout(output):
            fuzz.report_failure(directory, 123, 7, self.kinds[0], b'\xff\0\n\x1b',
                                b'partial', b'', 1, 'rejected compiler wrote stdout')
        lines = output.getvalue().splitlines()
        metadata = json.loads(lines[0])
        self.assertEqual(metadata['seed'], 123)
        self.assertEqual(metadata['index'], 7)
        self.assertEqual(metadata['failure'], 'rejected compiler wrote stdout')
        self.assertEqual(lines[1], "source=b'\\xff\\x00\\n\\x1b'")
        self.assertNotIn('Traceback', output.getvalue())
        self.assertNotIn('\x1b', output.getvalue())
        return lines

    def test_report_no_directory(self):
        self.assertEqual(len(self.report(None)), 2)

    def test_report_existing_file_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'existing'
            path.write_bytes(b'keep')
            lines = self.report(path)
            self.assertIn('artifact_error', json.loads(lines[2]))
            self.assertEqual(path.read_bytes(), b'keep')

    def test_report_unwritable_directory(self):
        with patch.object(Path, 'mkdir', side_effect=PermissionError('unwritable\x1b')):
            lines = self.report(Path('unused'))
        self.assertIn('artifact_error', json.loads(lines[2]))

    def test_report_exclusive_file_collision(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'source.pzl').write_bytes(b'keep')
            with patch.object(fuzz.tempfile, 'mkdtemp', return_value=tmp):
                lines = self.report(path)
            self.assertIn('FileExistsError', json.loads(lines[2])['artifact_error'])
            self.assertEqual((path / 'source.pzl').read_bytes(), b'keep')

    def test_report_artifacts_exact_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = self.report(Path(tmp))
            second = self.report(Path(tmp))
            first_path = Path(json.loads(first[2])['artifact'])
            second_path = Path(json.loads(second[2])['artifact'])
            self.assertNotEqual(first_path, second_path)
            self.assertEqual((first_path / 'source.pzl').read_bytes(), b'\xff\0\n\x1b')
            self.assertEqual((first_path / 'stdout.bin').read_bytes(), b'partial')
            self.assertEqual((first_path / 'stderr.bin').read_bytes(), b'')


if __name__ == '__main__':
    unittest.main()
