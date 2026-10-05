# sml

SQLite Modeling Language.

See [the v1 design](docs/design-v1.md) and [parser scope](docs/parser-plan.md).

## Parser

The library exports `parser.parse(allocator, source)`. It returns either an
arena-owned `.schema` or the first `.diagnostic` (message and byte span).
Allocation failure returns `error.OutOfMemory` separately.

Keep `source` alive while using the parsed schema. Pass `result.schema.schema`
to `resolver.resolve`, then free the parsed arena with `result.schema.deinit()`.
The resolved result owns its text and arrays and also requires `deinit()`.
Use `emitter.emit` to write the resolved schema as SQLite SQL.

Supported: braced tables, stored fields, `!` keys, nullable `?`, literal defaults,
`#name`, field `#allow reuse`, declaration docs, and field bodies using braces or
`=` with exactly two extra spaces. The string type is `str`, not `text` or
`string`. Boolean defaults use `true`/`false`; `bool` cannot be a primary key.
`datetime` accepts whole-second UTC `YYYY-MM-DDTHH:MM:SSZ` and insertion-time
`::now`. Inline `enum` fields use one or more field-level `#of` comma lists,
TEXT storage, and allowed-value checks. Bare enum words match
`[A-Za-z_][A-Za-z0-9_-]*`; backticks mean enum text, including in defaults.
Use whitespace before a `--` comment after a bare enum value (`a--b` is text).
Duplicate decoded values and empty sets are rejected; nullable enums may default
to `null`. Fractional seconds are deferred; reusable types are deferred indefinitely.
Field bodies support `? expr` and `#check expr` in either body form:

```text
Sample {
  value int? =
    ? _ > 0
    #check _ < 10
}
```

`_` refers only to that field, using its final SQL name; ordinary identifier
references are rejected in field checks. Backtick raw SQL is trusted and may
refer to other SQL columns, but `_` is not substituted within it. Roots must be
Boolean or trusted raw SQL. Nullable Boolean UNKNOWN passes SQLite CHECK;
use `_ != null` to explicitly reject NULL, or a nonnullable field for NOT NULL.
Explicit checks preserve source order and coexist with builtin type checks.
Table bodies support `?? expr` and `#check expr` anywhere among direct items,
including before fields. References use DSL field names, even with `#name` SQL
overrides, and can target fields declared later; `_` is invalid in table scope.
Single `?` is field-only; `??` is table-only. Table checks emit after columns and
any composite primary key, in check source order. Empty tables (including
checks-only tables) remain non-executable SQL skeletons.
Docs cannot target checks or unique constraints. Single-field `? unique` and
`#check unique` emit SQLite column `UNIQUE` constraints, after defaults/checks.
Optional same-line `{}` or multiline braces accept only `#name` backtick SQL
names (including hash-delimited backticks). Names are exact, safely quoted,
and unique ASCII-case-insensitively within each table, not global index names.
Table `?? unique(fieldA, fieldB)` / `#check unique(fieldA, fieldB)` support
composite uniqueness and the same optional `#name` body. One or more stored DSL
field names are required; references resolve after metadata, including forward
references and SQL `#name` overrides. SQL preserves the field list order.
Repeated fields, duplicate field sets (even reversed or field/table singletons),
and duplicate options are diagnosed. Table constraints follow PKs/checks.
Plain uniqueness allows multiple NULLs, including composite NULL components.
`unique(nulls: equal)` and named checks remain explicitly deferred.

Ordinary indexes support field `#index` (no arguments) and table
`#index fieldA, fieldB` (one or more DSL names, no trailing comma).
Forward references work; SQL preserves listed column order. Optional same-line
braces accept only exact backtick/hash-backtick `#name`, including empty `{}`.
Nested braced indexes work inside `=` field bodies; brace indentation is free,
but following siblings must return to exactly declaration indentation + 2.
Docs cannot target indexes or their options. `#unique`, `#where`, and expression
indexes are unsupported. Default names are
`{table_sql_name}_{column_sql_names_joined_by_underscore}_idx`.
Names are safely quoted, nonempty and NUL-free. Index names must be distinct
ASCII-case-insensitively across all tables and indexes, including later tables;
`sqlite_` prefixes are reserved for indexes. No numeric suffixes are added.
Repeated columns are rejected; repeated lists need distinct explicit `#name`
options. UNIQUE constraint names remain a separate table-local namespace.
SQL emits all CREATE TABLE statements before CREATE INDEX statements and
preflights the whole schema before writing.
Ordinary expressions such as `? unique == 'x'` still parse `unique` as an identifier.
Unsupported later-v1 syntax returns a diagnostic.

`expression_parser.parse(allocator, source)` separately parses one literal,
ordinary identifier reference (`[A-Za-z_][A-Za-z0-9_]*`), or standalone `_`
current-value expression. `true`, `false`, and `null` remain literals; words
such as `str`, `unique`, and `now` are references here. The result is an owned
`.expression` or a `.diagnostic`; call `result.expression.deinit()` on success
and keep the source alive because token text borrows it. Surrounding blank lines
and ordinary comments are allowed, but docs and trailing expressions are not.
Supported operators, from highest to lowest precedence: unary `!`, comparisons
`== != < <= > >=`, logical `&&`, then logical `||`. Binary operators associate
left; parentheses override precedence. Grouping, unary, and binary nodes share a
256-level structural depth limit; recursive nesting is also limited to 256.
Physical newlines and ordinary comments, including after operators, are allowed only
inside parentheses; indentation there is only formatting (leading tabs still fail).
Bare line continuations, dotted names, hyphenated enum references, single `|` pipe
bodies, and arithmetic are not supported; negative numeric literals remain valid.
References are not resolved, reusable types are deferred indefinitely, and this API
does not extend schema defaults; field and table checks use the same stream parser.

`expression_resolver.resolve(allocator, expression, context)` owns its resolved
result and permits scalar roots. For CHECKs, also call
`expression_resolver.validateCheckResult(&result.expression.expression)`; it returns
an optional diagnostic and requires Boolean or trusted raw SQL.

Operand typing (logical types, not SQLite storage coercions):

| Operators | Accepted DSL operands |
| --- | --- |
| `!`, `&&`, `||` | Boolean (including nullable Boolean references), not an untyped `null` literal |
| `==`, `!=` | Same family: numeric (int/real), text (str/enum), datetime, Boolean, blob references; or either operand a `null` literal |
| `<`, `<=`, `>`, `>=` | Numeric, text, or datetime family only |

Datetime also compares with a valid canonical `YYYY-MM-DDTHH:MM:SSZ` string
literal on either side, not a str/enum reference. Enum values compare as text;
no enum membership check applies here. Ordinary comparisons and logical operators
return Boolean and propagate operand nullability (SQL UNKNOWN); nullable Boolean
CHECK roots are accepted. Equality/inequality with a DSL `null` literal on either
side, including grouped literals or two nulls, lowers to resolved `is_null` /
`is_not_null` operators (SQL `IS` / `IS NOT`) with non-nullable Boolean results.
Grouping and operand order are preserved. Ordering against `null` is rejected.
Raw SQL has unknown type and is trusted, including whole CHECK roots, but cannot
excuse a known non-Boolean logical operand or known Boolean/blob ordering operand.
Raw SQL text `NULL` stays opaque; it is not a DSL null literal. Parsed operators
remain unchanged. The standalone APIs do not add schema constraints.
`expression_resolver.resolveInto(allocator, expression, context)` allocates into
a caller-owned arena and returns an expression or diagnostic without a child
arena; schema resolution uses this to own all check strings and trees.

`expression_emitter.emit(resolved.Expression, *std.Io.Writer) Error!void` writes
one SQLite expression (no statement or newline). It accepts scalar roots; use
resolver validation for operand types and CHECK roots. Operators are fully
parenthesized; `!` emits `NOT`, and lowered null comparisons emit `IS` / `IS NOT`
with the original operands. SQL names are double-quoted, text apostrophes are
doubled, and text NULs use encoding-independent `char(0)` concatenation, sharing
schema-default quoting. Trusted raw SQL is parenthesized without rewriting `_`
or any other content.

Preflight rejects structural depth above 256, nonfinite numbers, empty/NUL SQL
names, empty/NUL raw SQL, invalid enum tags, and unlowered comparisons with null
before writing anything. `expression_emitter.preflight(expression)` exposes the
same validation without output. Schema emission preflights every check and
validates CHECK roots before any SQL is written. It does not duplicate resolver operand typing or parse
trusted SQL. Writer failures return `error.WriteFailed` and may leave partial
output; callers own and flush the writer.

## Development

Use Zig 0.17.0.

```sh
zig build
zig build test
zig fmt --check build.zig build.zig.zon src
python3 src/testdata/boolean_runtime_test.py
python3 src/testdata/datetime_runtime_test.py
python3 src/testdata/encoding_runtime_test.py
python3 src/testdata/enum_runtime_test.py
python3 src/testdata/expression_runtime_test.py
python3 src/testdata/check_runtime_test.py
```

