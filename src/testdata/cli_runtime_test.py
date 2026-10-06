"""Build once and test the real sml executable (no database side effects)."""
import pathlib
import sqlite3
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
subprocess.run(['zig', 'build'], cwd=ROOT, check=True)
SML = ROOT / 'zig-out/bin/sml'
FIXTURES = ROOT / 'src/testdata/parser'


def run(args=(), source=b'', status=0, cwd=None):
    result = subprocess.run([str(SML), *map(str, args)], input=source,
                            capture_output=True, cwd=cwd, timeout=30)
    assert result.returncode == status, result
    if status == 0:
        assert result.stderr == b'', result.stderr
    else:
        assert result.stdout == b'', result.stdout
        assert result.stderr and b'\x1b' not in result.stderr, result.stderr
        assert b'panic' not in result.stderr and b'traceback' not in result.stderr.lower()
    return result


source = (FIXTURES / 'named_checks.sml').read_bytes()
expected = (FIXTURES / 'named_checks.expect.sql').read_bytes()
assert run(source=source).stdout == expected
assert run(['-'], source).stdout == expected
assert run([FIXTURES / 'named_checks.sml']).stdout == expected
assert run().stdout == b'PRAGMA foreign_keys = ON;\n'
assert run(['-']).stdout == b'PRAGMA foreign_keys = ON;\n'
for flag in ['--help', '-h']:
    assert run([flag]).stdout.startswith(b'Usage: sml [FILE|-]\n')
for args in [['--version'], ['--unknown'], ['-x'], ['a', 'b'],
             ['--help', 'a'], ['a', '-h'], ['--', 'a', 'b']]:
    assert run(args, status=2).stderr.startswith(b'Usage:')

# Invalid arguments must return even when stdin remains open (no EOF).
process = subprocess.Popen([str(SML), '--unknown'], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert process.wait(timeout=5) == 2
assert process.stdout.read() == b''
assert process.stderr.read().startswith(b'Usage:')
process.stdin.close()
process.stdout.close()
process.stderr.close()

syntax = b'Item {\n  value\n}\n'
assert run(source=syntax, status=1).stderr == (
    b'<stdin>:2:8: error [syntax]: Expected a declaration name\n'
    b'    value\n         ^\nnote: span continues beyond this line\n')
semantic = b'Item {\n  value Unknown\n}\n'
assert run(source=semantic, status=1).stderr == (
    b'<stdin>:2:9: error [unknown_type]: unknown type; supported builtins are '
    b'int, real, str, blob, bool, date, datetime, enum\n'
    b'    value Unknown\n          ^~~~~~~\n')
assert run(source=b'\x1b[31m\xff', status=1).stderr == (
    b'<stdin>:1:1: error [syntax]: invalid or unsupported character\n'
    b'  \\x1B[31m\\xFF\n  ^~~~\n')
assert b'16 MiB' in run(source=b' ' * (16 * 1024 * 1024 + 1), status=1).stderr
assert run(source=b' ' * (16 * 1024 * 1024)).stdout == b'PRAGMA foreign_keys = ON;\n'

with tempfile.TemporaryDirectory() as tmp:
    directory = pathlib.Path(tmp)
    for name in ['with spaces.sml', '-schema.sml']:
        path = directory / name
        path.write_bytes(source)
        assert run(['--', name], cwd=directory).stdout == expected
        assert path.read_bytes() == source
    bad = directory / 'bad.sml'
    bad.write_bytes(semantic)
    assert run([bad], status=1).stderr.startswith(str(bad).encode() + b':2:9:')
    assert bad.read_bytes() == semantic
    control_path = directory / '\x1bfile.sml'
    control_path.write_bytes(b'\xff')
    assert b'\\x1Bfile.sml' in run([control_path], status=1).stderr
    assert b'cannot open input: FileNotFound' in run([directory / 'missing'], status=1).stderr
    assert b'cannot read input:' in run([directory], status=1).stderr
    assert sorted(p.name for p in directory.iterdir()) == sorted([
        'with spaces.sml', '-schema.sml', 'bad.sml', '\x1bfile.sml'])

# Broken stdout is an ordinary exit-1 IO failure, not a panic or SIGPIPE.
process = subprocess.Popen([str(SML), FIXTURES / 'named_checks.sml'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
process.stdout.close()
assert process.wait(timeout=10) == 1
assert b'output failed' in process.stderr.read()
process.stderr.close()

# Regression: namespace validation runs in both resolution and emission. Large
# named-check schemas must not trigger cubic indexed rescans. The ordinary
# subprocess timeout is only a hang guard, not a benchmark assertion.
large_source = ('Many {\n  value int\n' + ''.join(
    '  ?? value >= 0 {{\n    #name `check_{}`\n  }}\n'.format(i)
    for i in range(2000)) + '}\n').encode()
large_sql = run(source=large_source).stdout
assert large_sql.count(b'CONSTRAINT "check_') == 2000
assert b'CONSTRAINT "check_1999" CHECK' in large_sql

# Execute only in the test's own in-memory DB. CLI never opens SQLite.
db = sqlite3.connect(':memory:')
db.executescript(expected.decode())
assert db.execute('PRAGMA foreign_keys').fetchone() == (1,)
db.execute('INSERT INTO "named ranges" VALUES (1, 9)')
try:
    db.execute('INSERT INTO "named ranges" VALUES (9, 2)')
except sqlite3.IntegrityError as error:
    assert str(error) == 'CHECK constraint failed: range "order"'
else:
    raise AssertionError('named CHECK was not enforced')
db.close()
print('CLI stdin/file, diagnostics, IO, arguments and SQLite checks passed')
