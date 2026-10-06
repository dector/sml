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

Indexes support field `#index` (no arguments) and table
`#index fieldA, fieldB` (one or more DSL names, no trailing comma).
Forward references work; SQL preserves listed column order. Optional same-line
braces accept exact backtick/hash-backtick `#name` and argument-free `#unique`,
including empty `{}`. `#unique` emits CREATE UNIQUE INDEX; otherwise indexes
are ordinary. Duplicate flags are diagnosed; arguments and bodies are rejected.
Nested braced indexes work inside `=` field bodies; brace indentation is free,
but following siblings must return to exactly declaration indentation + 2.
Docs cannot target indexes or their options. Standalone `#unique`, `#where`,
and expression-index columns are unsupported (their grammar remains unsettled).
Slice18 adds `#where expr` inside field/table index braces. It uses the shared
expression parser, including grouped multiline expressions. Predicates resolve
in table row scope: DSL field names (including forward references and `#name`
mapping) work; `_` is invalid even for field indexes. The root must be Boolean
or trusted raw SQL. Duplicate `#where` is diagnosed. SQL emits WHERE after the
quoted column list; all predicate trees are preflighted before any schema output.
SQLite restrictions apply: no nondeterministic functions, subqueries, or bound
variables. Trusted raw SQL is not statically checked for those restrictions.
With `#unique`, only predicate-matching rows participate in uniqueness; no
constraint rewrite occurs. Unique indexes use SQLite's distinct
NULL semantics, like native `? unique` constraints. Default names are
`{table_sql_name}_{column_sql_names_joined_by_underscore}_idx`.
Names are safely quoted, nonempty and NUL-free. Index names must be distinct
ASCII-case-insensitively across all tables and indexes, including later tables;
`sqlite_` prefixes are reserved for indexes. No numeric suffixes are added.
Repeated columns are rejected; repeated lists need distinct explicit `#name`
options, including an ordinary and unique index on the same ordered columns:
both default to the same `_idx` name. Native UNIQUE constraint names remain a
separate table-local namespace.
SQL emits all CREATE TABLE statements before CREATE [UNIQUE] INDEX statements and
preflights the whole schema before writing.
Ordinary expressions such as `? unique == 'x'` still parse `unique` as an identifier.
Unsupported later-v1 syntax returns a diagnostic.

StoredFK Slice4 emits stored foreign keys and deletion actions. `*field Table?`
looks up the exact DSL table name (including forward/self references), requires
one declared PK field, and inherits its logical type and enum allowed values.
SQL target names honor `#name` and are owned by the resolved schema. Nullability,
defaults, docs, checks, and uniqueness belong to the local FK declaration;
local defaults are validated against the inherited type. Enum FK defaults use
bare words or backtick text; datetime FK defaults also accept `::now`.
Keyless/composite targets and type-dependency cycles are diagnosed. `*!field`
resolves shared identity, including chains to concrete PK types; `#allow reuse` is invalid
on every FK. Field `#onDelete restrict`, `cascade`, and `setNull` emit quoted
`REFERENCES table(column) ON DELETE RESTRICT`, `CASCADE`, or `SET NULL`.
The default is restrict; setNull requires local nullability. Duplicate actions,
unknown actions, and table/non-FK scope are diagnosed. `#onUpdate` is unsupported.
Deferrability is unspecified. Forward, self, and mutual ordinary references work.
Shared-PK FKs are nonnullable and never generate IDs. Single integer PK+FK tables
emit `STRICT, WITHOUT ROWID`; composite and noninteger keys use ordinary STRICT
tables with every PK part NOT NULL. Type-compatible defaults are allowed but must
reference existing parents at runtime; omission without a default and explicit NULL
fail. Ordinary integer PKs retain AUTOINCREMENT and NULL ID generation.
StoredFK Slice6 resolves ordinary, nonunique FK indexes unless the FK is the
leading column of a primary key, field/composite UNIQUE constraint, or full
ordinary/unique index. Each single-column FK is checked independently. Partial
indexes never count, even with a constant-true predicate. Full UNIQUE indexes
cover nullable FKs too. A shared single-column PK+FK needs no extra index.
Explicit indexes and names are resolved globally first. Generated names use
`{table_sql}_{column_sql}_idx` and share the ASCII-case-insensitive table/index
namespace. Collisions diagnose the FK field; no suffix is added. Rename an
explicit partial index if it occupies the generated name, or rename the table/
column when needed. Direct resolved-model emission only emits supplied indexes.
Nonnullable set-null metadata
fails emitter preflight before any output.
Public resolved schemas must supply consistent FK metadata: SQL names match
ASCII-case-insensitively, the target has exactly one real PK, and logical types
and enum value sets match exactly (enum order does not matter). Invalid metadata
or defaults fail whole-schema preflight before any output is written.
SQLite enforcement requires `PRAGMA foreign_keys = ON` **on every connection,
before starting a transaction**. The emitted script includes this PRAGMA, but
running it inside an already-open transaction does not enable enforcement.

VirtualRelationships Slice4 resolves direct collections such as
`~books Book[] @Book.publisher`. Target and source use exact DSL table names;
they must be the same table. The source names a stored FK pointing to the owner's
single PK, using final SQL names (including `#name`). The collection target may
be keyless. Forward/self mappings work. Virtual names share the exact,
case-sensitive DSL namespace with stored fields and other relationships, not
SQL identifiers. Owned metadata preserves docs/spans and table/declaration order;
relationships produce no SQL. Relationship documentation is preserved as owned,
text-only metadata in this interim implementation; it is not discarded and does
not emit SQL comments. SQL output placement remains an open design decision.
Direct singular relationships (`~author Author? @Author.profile`) are supported.
They must be nullable, and their backing FK must have a single-column PK,
field/table UNIQUE, or full single-column unique index. Composite keys and all
partial indexes (even `#where true`) do not prove singular cardinality. Nullable
backing FKs are allowed: multiple NULLs reference no owner. Collections must be
nonnullable and need no uniqueness.
Relationships cannot carry defaults/directives. Public relationship metadata is
validated across the whole schema before any SQL is written; invalid mappings,
indices, names, collisions, or cardinality proofs return `InvalidRelationship`.

```pzl
Owner {
  !id int
  --- All stored items for this owner
  ~items Item[] @Item.owner
  --- At most one item, proven by the real UNIQUE below
  ~profile Item? @Item.owner
}
Item {
  *owner Owner? {
    ? unique
  }
}
```

NamedConnections supports named stored connections with explicit `*!`
keys or a standalone body `~~` marker. Each normal endpoint table must have exactly one PK. The connection
PK FK targets must exactly match the endpoint multiset; payload fields and
additional non-PK FKs are allowed. Composite PK SQL preserves written key order.
Repeated-table endpoints require distinct explicit roles. Resolved header-order
`connection.endpoints` own exact roles and stable `table_index` values. Unique-table
endpoints bind `column_index`; explicit repeated-table roles leave it null.
Generated endpoints bind their header-ordered columns, including self roles.
For explicit keys, neither names nor declaration order imply role binding. SQL preflights public
connection metadata and returns `InvalidConnection` before output on violations.
NamedConnections Slice3 supports endpoint mappings through declared connections:
`~books Book[] @Borrow.reader` or `~following Reader[]
@Following.leftReader <<rightReader`. The source field must be an endpoint PK FK
to the owner. Destination candidates are the other endpoint PK FK fields to the
declared target. Exactly one is inferred; multiple candidates require `<<field`.
A hint names an exact stored **DSL field**, never a header role or SQL alias.
Self-connections use different source/destination fields, with no role naming
convention. Grammar: `~name Target[] @Connection.source [<<destination]` (or
`Target?` for singular). Direct backrefs cannot carry hints. A different source
and target requires a declared connection.

Collections preserve connection tuples: there is no implicit deduplication or
ordering. Nullable singular mappings require the source key alone to be globally
unique (single-column PK/UNIQUE/full unique index); a composite connection PK
alone does not suffice. The destination FK already identifies one target record.
All relationships remain virtual and emit no SQL, including their documentation.
NamedConnections Slice4 exercises the complete explicit-key pipeline and SQLite
runtime behavior; it adds no generated features. For implemented explicit keys,
header endpoint order is metadata order, **not key order**. Every endpoint key
must be supplied on insert: there is
no automatic prefill or ID generation for connection keys. Payload defaults,
checks, uniqueness, indexes, and FK deletion policies behave like ordinary tables.
The PK covers reverse FK lookups only for its first key; remaining uncovered FKs
receive ordinary indexes. Nested endpoints remain deferred.

Named `~~` generation is supported end to end. It expands before field/type
resolution without changing parsed source fields or documentation. Generated
nonnullable PK FKs come first in **header order**, before all explicit payload
fields, regardless of the marker's body position. Unmodified generated keys have
no defaults or options; insert must supply those keys. Each endpoint requires one
normal-table declared PK, including FK PK chains.

DSL names are `camelCase(table-or-role DSL name) + PascalCase(PK DSL field name)`:
`Author.id` → `authorId`, `writer.accountKey` → `writerAccountKey`,
`Snake_Name.account_key` → `snakeNameAccountKey`. Underscores are removed and
uppercase the following character; leading underscores are stripped. Only the
initial character changes case otherwise, preserving existing humps/acronyms
(`URL` → `uRL`). All-underscore components and generated-name collisions are
errors: declare distinct roles or explicit keys. Parent SQL `#name` aliases do
not affect generated DSL names; ordinary SQL normalization remains unchanged.
An explicit field with the exact generated DSL name overrides that slot without
moving it or adding a duplicate. For example:

```pzl
~Books(Author, Book) {
  ~~
  --- Custom writer column.
  *!authorId Author {
    #name `writer_id`
    #onDelete cascade
  }
}
```

Overrides must remain nonnullable primary-key stored FKs targeting the exact DSL
endpoint, and cannot use `#allow reuse`. Docs, SQL names, FK actions, valid
inherited-type defaults, checks, uniqueness and indexes retain ordinary stored-FK
semantics. Duplicate explicit DSL names are still errors. Other explicit fields
follow all generated slots in source order; extra PKs fail connection validation.
Repeated-table roles bind to their generated slots, including overrides.

Explicit unnamed connections support exactly two distinct, unroled endpoints:
`~(Author, Book) { ... }`. Their canonical identity is the bytewise-sorted pair
of exact DSL table names, independent of SQL `#name` overrides. Reversed headers
are the same identity and duplicate declarations are errors. Named connections
with these endpoints remain distinct. The synthesized DSL name is
`Author__n__Book`; the default SQL name normalizes each DSL endpoint separately
and joins them with `__n__`, yielding `author__n__book`. Parent SQL aliases do not
affect it; a connection `#name` overrides only its SQL name. Normal namespace
collision checks still apply. Explicit `@Author__n__Book.field` mappings may use
the synthesized DSL name.

Unnamed `~~` keys and endpoint metadata use canonical endpoint order; authored
keys without `~~` retain exact written order. Without `~~`, all endpoint keys
must be written: there is no implicit generation. Unnamed roles, self-pairs and
more than two endpoints are unsupported. Shorthand `@.field` and implicit
connection generation remain pending.

Complete explicit-key example (forward mappings are allowed):

```text
Reader {
  !id real
  ~books Book[] @Borrow._sourceId
  ~following Reader[] @Following.leftKey
  ~peers Reader[] @Trio.first <<second
}
Book {
  !id str
}
~Borrow(person Reader, publication Book) {
  *!bookKey Book
  position int(0)
  *!_sourceId Reader {
    #onDelete cascade
  }
}
~Following(follower Reader, followed Reader) {
  *!leftKey Reader
  *!rightKey Reader
}
~Trio(actor Reader, peer Reader, context Reader) {
  *!third Reader
  *!second Reader
  *!first Reader
}
```

`Borrow` has PK `(bookKey, _sourceId)`, not header order. `Following` infers
`rightKey`; `Trio` needs `<<second` because two other keys target `Reader`.
Its PK remains `(third, second, first)`. Repeated-table roles remain unbound
(`column_index = null`); relationship destination indices are independently
resolved from explicit fields. These declarations generate stored tables and FK
indexes, not relationship queries, deduplication, or sorting.

Read `result.schema.schema.relationships` after resolution. Each entry has an
owned `dsl_name`, declaration/documentation spans, optional documentation text,
cardinality, and zero-based `owner_table_index`, `target_table_index`,
`source_table_index`, `backing_column_index`, and optional
`destination_column_index` (null for direct mappings, filled for every connection
mapping, including inferred destinations). Table indices refer to resolved
`tables`; both column indices refer to the source table's stored `columns`, not
its interleaved declaration position. The resolved arena owns this metadata:
parsed storage and source can be freed before reading it or emitting SQL.
Direct mappings describe existing FKs. They are **not query loading** and create
no SQL columns, constraints, tables, or indexes. Real FK index coverage is
unchanged. Emitter preflight checks endpoint membership and FK directions;
incomplete connection metadata is rejected, never inferred during emission.

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
# Run every SQLite runtime fixture:
for test in src/testdata/*_runtime_test.py; do python3 "$test"; done
```

