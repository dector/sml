"""Bounded deterministic CLI fuzzing; SQLite oracle only for generated safe DSL.

No builds, fixture rewrites, queries, or dependencies beyond Python's stdlib.
See README.md for the intentionally weaker oracle on arbitrary byte mutations.
"""
import argparse
from contextlib import closing
import json
import random
import re
import sqlite3
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SEED = 5265996
MAX_BYTES = 8192


def generated(rng):
    """Known-valid grammar, typed expressions, unique SQL names; no raw SQL."""
    number = rng.randrange(0, 1000)
    text = rng.choice(["plain", "O''Brien", "雪😀", "line\\nend", "nul\\0end",
                       "quote\"; -- not SQL"])
    date = rng.choice(["2000-02-29", "2024-01-01", "0001-01-01"])
    check = rng.choice(["low <= high", "low == null || high != null",
                        "!(low > high)", "low >= 0 && high >= low",
                        "low != null || high == null"])
    where = rng.choice(["enabled && low < high", "low != null", "high >= 0"])
    # Backticks here are ONLY SQL-name / enum-text syntax, never trusted SQL.
    sql_name = rng.choice(['ordinary', 'quoted " name', '雪 name', 'x; -- text'])
    connection = rng.choice([
        "~Pair(left Owner, right Owner) {\n  ~~\n  label str('ready')\n}\n",
        "~Triple(left Owner, right Owner, context Owner) {\n  ~~\n}\n",
        "",
    ])
    return f'''--- Generated safe documentation.
Owner {{
  #name `owner {sql_name}`
  !id int
  ~items Item[] @Item.owner
  label str('{text}')
}}
Item {{
  #name `item {sql_name}`
  !id int
  *owner Owner? {{
    #onDelete cascade
    #index {{
      #name `owner lookup`
    }}
  }}
  low int?({number}) {{
    ? _ >= 0 {{
      #name `nonnegative low`
    }}
  }}
  high int?({number + 1})
  enabled bool({rng.choice(['true', 'false'])})
  ratio real({number}.25)
  note str('{text}')
  day date('{date}')
  moment datetime('{date}T00:00:00Z')
  state enum(draft) {{
    #of draft, done, `it's ready`, `雪`
  }}
  #check {check} {{
    #name `range check`
  }}
  #index low, high {{
    #name `range lookup`
    #where {where}
  }}
  #index note {{
    #unique
    #name `note unique`
  }}
}}
{connection}'''.encode('utf-8')


def mutated(rng, fixtures):
    data = bytearray(rng.choice(fixtures))
    tokens = [b'\x00', b'\xff\xfe', b'\x1b\r\t', b"'", b'`', b'--- ',
              b'--\n', b'{}', b'()', b'#name', b'\\0', b'\n', b'\xc0\xaf']
    for _ in range(rng.randrange(1, 9)):
        pos = rng.randrange(len(data) + 1)
        op = rng.randrange(4)
        if op == 0:
            data[pos:pos] = rng.choice(tokens)
        elif op == 1:
            del data[pos:pos + rng.randrange(1, 33)]
        elif op == 2 and pos < len(data):
            data[pos] ^= 1 << rng.randrange(8)
        else:
            data[pos:pos + rng.randrange(0, 16)] = bytes(
                rng.randrange(256) for _ in range(rng.randrange(1, 33)))
    return bytes(data[:MAX_BYTES])


def case(seed, index, fixtures):
    # Independent streams permit reproducing an index with a longer run.
    rng = random.Random((seed << 64) + index)
    if index % 4 in (0, 1):
        return 'generated-sql', generated(rng)
    if index % 8 == 6:
        # Target accepted literal/documentation/name bytes, not only rejection.
        data = generated(rng)
        payload = rng.choice([b'\xff', b'\xc0\xaf', b'\x00', b'\x1b',
                              b"' quoted -- text", '雪'.encode()])
        location = rng.randrange(3)
        if location == 0:
            data = b'--- ' + payload + b'\n' + data
        elif location == 1:
            data = data.replace(b'ordinary', payload)
        else:
            data = data.replace(b"str('", b"str('" + payload, 1)
        return 'literal-comment-mutation-status-only', data
    if index % 4 == 2:
        return 'fixture-mutation-status-only', mutated(rng, fixtures)
    return 'arbitrary-bytes-status-only', bytes(
        rng.randrange(256) for _ in range(rng.randrange(0, 1025)))


def artifact(directory, seed, index, kind, source, stdout, stderr, status, reason):
    if directory is None:
        return None
    directory.mkdir(parents=True, exist_ok=True)
    # mkdtemp creates an exclusive per-case directory: never overwrite artifacts.
    path = Path(tempfile.mkdtemp(prefix=f'seed-{seed}-index-{index}-', dir=directory))
    for name, data in [('source.pzl', source), ('stdout.bin', stdout),
                       ('stderr.bin', stderr)]:
        with (path / name).open('xb') as stream:
            stream.write(data)
    with (path / 'metadata.json').open('x', encoding='utf-8') as stream:
        json.dump(dict(seed=seed, index=index, kind=kind, status=status,
                       reason=reason), stream, ensure_ascii=True, indent=2)
    return path


def report_failure(directory, seed, index, kind, source, stdout, stderr, status, reason):
    # Report first: filesystem failures must never hide the original failure.
    print(json.dumps(dict(failure=reason, seed=seed, index=index, kind=kind),
                     ensure_ascii=True))
    print(f'source={source!r}')
    try:
        path = artifact(directory, seed, index, kind, source, stdout, stderr,
                        status, reason)
    except OSError as exc:
        print(json.dumps(dict(artifact_error=f'{type(exc).__name__}: {exc}'),
                         ensure_ascii=True))
    else:
        if path is not None:
            print(json.dumps(dict(artifact=str(path)), ensure_ascii=True))


def validate_generated_sql(source, stdout):
    # Read only fixed generator syntax, not arbitrary DSL. No RNG calls or case
    # changes: each seed/index continues to produce exactly the same input bytes.
    owner, item = [name.decode('utf-8') for name in re.findall(
        rb'^  #name `((?:owner|item) [^`]+)`$', source, re.MULTILINE)]
    connection = 'pair' if b'~Pair(' in source else (
        'triple' if b'~Triple(' in source else None)
    expected = {('main', owner, 'table', 2, 0, 1),
                ('main', item, 'table', 10, 0, 1),
                ('main', 'sqlite_sequence', 'table', 2, 0, 0),
                ('main', 'sqlite_schema', 'table', 5, 0, 0),
                ('temp', 'sqlite_temp_schema', 'table', 5, 0, 0)}
    if connection:
        expected.add(('main', connection, 'table', 3, 0, 1))
    with closing(sqlite3.connect(':memory:')) as db:
        db.execute('PRAGMA foreign_keys = ON')
        db.executescript(stdout.decode('utf-8', errors='strict'))
        actual = set(db.execute('PRAGMA table_list'))
        if actual != expected:
            raise ValueError(f'generated table_list mismatch: expected {sorted(expected)!r}, '
                             f'got {sorted(actual)!r}')
        # Parameterize table-valued PRAGMAs: generated names can contain quotes.
        foreign_keys = list(db.execute('SELECT * FROM pragma_foreign_key_list(?)', (item,)))
        if len(foreign_keys) != 1 or foreign_keys[0][2:5] != (owner, 'owner', 'id'):
            raise ValueError('generated Item foreign key shape mismatch')
        indexes = {row[0] for row in db.execute(
            'SELECT name FROM sqlite_schema WHERE type = ? AND tbl_name = ?',
            ('index', item))}
        if indexes != {'owner lookup', 'range lookup', 'note unique'}:
            raise ValueError('generated Item index names mismatch')


def validate_result(kind, source, result):
    """CLI output contract applies even when SQL is intentionally not decoded."""
    if result.returncode not in (0, 1):
        return f'unexpected compiler status {result.returncode}'
    if result.returncode == 0 and result.stderr:
        return 'successful compiler wrote stderr'
    if result.returncode == 1:
        if result.stdout:
            return 'rejected compiler wrote stdout'
        if not result.stderr:
            return 'rejected compiler wrote no diagnostic'
        if kind == 'generated-sql':
            return 'known-valid generated DSL rejected'
    elif kind == 'generated-sql':
        validate_generated_sql(source, result.stdout)
    return None


def unsigned(value):
    if not value.isascii() or not value.isdecimal():
        raise argparse.ArgumentTypeError('expected an unsigned decimal integer')
    return int(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iterations', type=unsigned, default=500)
    parser.add_argument('--seed', type=unsigned, default=DEFAULT_SEED)
    parser.add_argument('--failure-dir', type=Path)
    parser.add_argument('--compiler', type=Path, default=ROOT / 'zig-out/bin/sml')
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error('--iterations must be positive')
    if not args.compiler.is_file():
        parser.error('compiler missing; run zig build first or pass --compiler')
    fixtures = [p.read_bytes() for p in sorted((ROOT / 'src/testdata/parser').glob('*.sml'))]
    if not fixtures:
        parser.error('parser fixture corpus is empty')
    stats = dict(sql_executed=0, status_only=0, rejected=0,
                 status_only_non_utf8=0, status_only_sql_nul=0)
    samples = []
    for index in range(args.iterations):
        kind, source = case(args.seed, index, fixtures)
        stdout, stderr, status, reason = b'', b'', None, None
        try:
            result = subprocess.run([str(args.compiler.resolve()), '--', '-'],
                                    input=source, capture_output=True, timeout=5)
            stdout, stderr, status = result.stdout, result.stderr, result.returncode
            reason = validate_result(kind, source, result)
            if reason is None and kind == 'generated-sql':
                stats['sql_executed'] += 1
            elif reason is None:
                stats['status_only'] += 1
                stats['rejected'] += int(status == 1)
                if status == 0:
                    # Observations, NOT SQL failures: these cases may contain
                    # trusted raw SQL and byte-preserving documentation.
                    stats['status_only_sql_nul'] += int(b'\0' in stdout)
                    try:
                        stdout.decode('utf-8', errors='strict')
                    except UnicodeDecodeError:
                        stats['status_only_non_utf8'] += 1
                        if len(samples) < 5:
                            samples.append(index)
        except subprocess.TimeoutExpired as exc:
            stdout, stderr = exc.stdout or b'', exc.stderr or b''
            reason = 'compiler timed out after 5 seconds'
        except (ValueError, sqlite3.Error, OSError) as exc:
            reason = f'{type(exc).__name__}: {exc}'
        if reason:
            report_failure(args.failure_dir, args.seed, index, kind, source,
                           stdout, stderr, status, reason)
            return 1
    print(json.dumps(dict(seed=args.seed, iterations=args.iterations, **stats,
                          non_utf8_sample_indices=samples), ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
