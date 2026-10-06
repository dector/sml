# Parser plan

Named and unnamed explicit connection headers support connection tables as
endpoints, including forward references. Resolution expands dependencies before
key/type resolution. `~~` expands the full target PK in its written order;
local DSL names use the endpoint role (otherwise table name) plus each PascalCase
target key name, with the existing underscore-removal camel convention.
For example Authorship's `authorId`, `bookId` become Credit's
`authorshipAuthorId`, `authorshipBookId`, followed by `organizationId`.
The nested keys emit one table-level composite FK to Authorship(authorId, bookId),
not separate leaf-table FKs. Explicit `*!pair Authorship` expands to
`pairAuthorId`, `pairBookId`. Tuple declarations allow only `#onDelete` and reject
scalar defaults, names, checks and other scalar options. Individual `~~` slots
may override those options while retaining the same Authorship target; composite
FK components must agree on deletion policy. Inherited keys are nonnullable and
never auto-generated. Cycles report `invalid_connection`; nesting is capped at
256 levels. Normal endpoints still require exactly one PK.
Composite-endpoint virtual relationship mappings are unsupported. Implicit `@.`
shorthand still requires normal endpoints; ordinary scalar relationship mappings
and nested braces are unchanged.
Coverage: `src/nested_connection_test.zig`,
`src/testdata/parser/nested_connections.sml` and
`src/testdata/nested_connections_runtime_test.py`.

Slice1 named CHECK constraints are implemented. Field/table `#check expr`,
`? expr` and `?? expr` accept optional same-line braces using the native UNIQUE
options parser: empty `{}` or a multiline body with exactly one `#name` literal.
Unknown/nested options, duplicate arguments and docs attachments are rejected.
The expression stream stops before the opening brace, including grouped roots.
Parsed directives retain an optional name token; resolved checks own
`Check { expression, name }` wrappers in the schema arena. All expressions and
nonempty UTF-8/NUL-free names are preflighted before output. Named UNIQUE and
CHECK share an ASCII-case-insensitive table-local namespace across field/table
scope; builtin checks stay unnamed. Names emit safely quoted CONSTRAINT labels
and SQLite INSERT/UPDATE errors expose the exact label. Tests cover forward
references, nullable UNKNOWN, NULL rewrites, trusted raw SQL, quoting, namespace
collisions and full-pipeline allocation failures (`src/named_check_test.zig`,
`named_checks.sml`/SQL and `src/testdata/named_check_runtime_test.py`).

Status: the first supported parser milestone (stages 1–4) is implemented and
covered by tokenizer, parser, allocation-failure, and source-to-SQL tests.
Stage 5 is partially implemented, including partial indexes, stored FKs,
virtual relationships, generated keys/overrides, extended explicit unnamed
connections, explicit nested endpoints, exact-pair shorthand, and logical `date`. Stages below retain their
historical milestone scope; they are not a complete list of current support.
`? unique` / `#check unique` preserve a native_unique payload with empty field
references and ordered, spanned options. Same-line brace options support exact
backtick #name only; duplicates are preserved for resolver diagnostics.
The resolved column carries unique_constraints; SQLite emission uses safely
quoted optional CONSTRAINT names followed by UNIQUE after defaults/checks.
Table-local constraint names compare ASCII-case-insensitively, independently
of index object names. Table `?? unique(a, b)` / `#check unique(a, b)` now
preserve ordered reference tokens and the same optional name body. Resolution
runs after all column metadata; resolved table constraints own column indices.
One or more stored fields are required. Repeated references and duplicate sets
(including reversed lists and field/table singleton duplicates) are rejected.
The emitter validates indices and names before output and writes ordered,
quoted table UNIQUE items after PKs/checks. Plain NULLs remain distinct.
Slice16 supports field `#index` and table `#index a, b`, with forward DSL
references and ordered column indices in owned resolved.Table.indexes.
Slice17 adds argument-free `#unique` inside field/table index options.
Optional same-line braced options accept exact backtick/hash-backtick `#name`
and `#unique`; empty `{}` works. Duplicate names/flags retain spans and are
rejected by the resolver. Flag arguments/bodies and standalone `#unique` fail.
Resolved Index.unique defaults false; true emits CREATE UNIQUE INDEX using
SQLite's distinct NULL semantics. Native `? unique` constraints are unchanged.
Nested braced indexes in `=` field bodies use free brace indentation but exact
+2 sibling indentation. Docs cannot attach to indexes or options.
Default names are `{table_sql_name}_{column_sql_names_joined_by_underscore}_idx`.
Names are nonempty/NUL-free; all tables/indexes share an ASCII-case-insensitive
namespace including later declarations. Index `sqlite_` prefixes are reserved.
No suffixing: repeated column lists need distinct explicit names, including
ordinary/unique indexes on the same columns (both still default to `_idx`).
Repeated columns fail. Native UNIQUE labels remain table-local and separate. Whole-schema
preflight validates manual resolved input before writing all tables then indexes.
Slice18 adds spanned, duplicate-preserving `#where expr` options using the shared
expression stream parser, including grouped multiline expressions. Predicates
resolveInto the parent arena after all columns, in table row scope even for
field indexes: DSL names map to final SQL names; `_` is invalid. Boolean roots
or trusted raw SQL are required. Whole-schema expression preflight precedes any
output. WHERE follows the quoted indexed columns; combined #unique applies only
to matching rows without rewriting native uniqueness or distinct NULL behavior.
SQLite disallows nondeterministic functions, subqueries and bound parameters;
trusted raw SQL restrictions are not statically evaluated.
`unique(nulls: equal)` and expression-index columns remain deferred;
expression-index grammar is unsettled. Native UNIQUE and expression CHECK
constraint `#name` bodies are supported as described above. Unsupported syntax
is diagnosed rather than ignored.
See [the language design](design-v1.md) for broader v1 scope.

## Goal and first milestone

Add source text → `parsed.Schema` to the existing resolver/emitter pipeline.
Implement the supported subset first, not the entire v1 language upfront.

The first milestone supports:

- Braced tables and stored fields.
- `!` primary-key markers, named type references, and nullable `?`.
- Defaults represented by the current parsed model: integers, reals, ordinary and
  raw text strings, booleans (`true`/`false`), null, and raw SQL.
- `#name` and field-level `#allow reuse`.
- Built-in string type `str`, emitted as SQLite `TEXT`; `text` and `string` are
  not DSL aliases. The resolver now uses `str`; SQLite storage and internal
  text-value representations remain unchanged.
- Indentation-based `=` and braced field bodies.
- Source-only comments and preserved declaration documentation.
- Ordinary and hash-delimited backticks.

Unknown type names parse successfully; resolution reports unsupported/unknown
references. Recognizable unsupported syntax produces explicit diagnostics, not
silently ignored declarations. Built-in `bool` is now supported with INTEGER
storage, a generated `CHECK (column IN (0, 1))`, and type-compatible defaults.
Boolean fields cannot be primary keys, including composite keys. This is settled
policy, not deferred work. Boolean `#allow reuse` is invalid. Resolution and
emission reject Boolean keys before SQL output.
Built-in `datetime` is supported with TEXT storage and explicit runtime format
and Gregorian calendar checks. String defaults resolve to validated timestamps.
Only contextual `datetime(::now)` generator defaults are supported, emitting
`strftime('%Y-%m-%dT%H:%M:%SZ','now')`. The exact format is
`YYYY-MM-DDTHH:MM:SSZ`, years 0001–9999, real Gregorian dates, hours 00–23,
minutes/seconds 00–59. Offsets, leap seconds, and fractional seconds (even `.000`)
are rejected; fractional precision is later work. Nullable NULL passes. Datetime
keys are not auto-generated integers. Raw SQL defaults face the same runtime
checks. See `src/datetime_test.zig` and `src/testdata/datetime_runtime_test.py`.
Built-in logical `date` uses TEXT with exactly ASCII `YYYY-MM-DD`, years
0001–9999, and Gregorian calendar validation. Decoded string defaults are
validated; raw SQL defaults must pass runtime checks. Nullable NULL, ordinary
PKs/FKs, checks, and index predicates are supported. Comparisons accept dates
or canonical date string literals, not datetime or ordinary text references.
Dates have no timezone or generator; `::now` remains datetime-only. See
`src/date_test.zig` and `src/testdata/date_runtime_test.py`.
Inline enums are implemented with TEXT storage and `CHECK (column IN (...))`.
Field-level enum-only `#of` lines accumulate comma-separated members in either
body form. Lists cannot be empty, omit a member, have trailing commas, or span
lines. Duplicate decoded bytes are errors; no case folding or Unicode
normalization applies. Empty backtick text is a valid member.

Bare enum words use `[A-Za-z_][A-Za-z0-9_-]*`, scanned maximally in an explicit
contextual tokenizer mode. `a--b` is text; whitespace before `--` starts an
ordinary comment after a bare member. Declaration identifiers stay narrow, so
`str--comment` still means type plus comment. Backticks are scanned atomically.
Enum defaults use the same bare/backtick text syntax and must belong to the set.
Bare `null` is a nullable default only; backtick `null` is text. Contextual
`true`, `false`, and `_` are valid enum words. Strings, numbers, and `::now` are
invalid enum defaults. Enum keys have TEXT semantics, no automatic IDs, and
cannot use `#allow reuse`. Stored arrays remain unsupported.

Parsed member/default tokens borrow source and retain spans. Resolution owns the
decoded arrays and text. Resolver and emitter independently validate enum
metadata and defaults at their API boundaries, before SQL output. The direct
resolved `.raw_sql` default remains a trusted escape hatch; parser enum
backticks are text, not SQL. Backtick values may contain valid UTF-8 and NUL;
malformed UTF-8 is rejected.
Enum and `str` SQL text share quoted chunks plus `char(0)` for NUL, preserving
text in UTF-8/UTF-16 (see design section 15). Tests: `src/enum_test.zig`, the
`enum.sml`/SQL fixture, and `src/testdata/enum_runtime_test.py`.

Slice12 field checks are implemented end-to-end: `? expr` and `#check expr`
in both `=` and braced field bodies. The expression stream parser retains
original byte spans, nesting limits, and multiline trivia inside parentheses.
Trailing type `?` still means nullable. Docs cannot attach to checks.

Resolution waits for column metadata and final SQL names, then resolves each
check in field scope: `_` is the current field only; identifiers are forbidden.
Backtick raw SQL is trusted and may refer to other SQL names without placeholder
rewriting. Boolean (including nullable Boolean) or raw-SQL roots are required.
Resolved columns own an ordered `checks` Check wrapper array in the schema arena.
The emitter preflights all expressions and roots before any SQL; explicit checks
follow builtin enum/bool/date/datetime checks and preserve their source order.
`_ != null` emits `IS NOT NULL`; ordinary nullable comparisons retain SQL UNKNOWN.
Named expression CHECK bodies and native UNIQUE constraint names are supported
as described in Slice1 above.
Tests: `src/check_test.zig`, `src/check_extra_test.zig`, `checks.sml`/SQL fixture,
and `src/testdata/check_runtime_test.py`.

Slice13 table checks are implemented end-to-end: direct table `?? expr` and
`#check expr` can precede or follow fields. Parsed directives retain check payloads
and source order. Resolution runs after all columns are known, with
`expression_resolver.Context { .table = table, .field_index = null }`:
DSL names resolve to final SQL names (including quoted `#name` overrides),
forward references work, and `_` is invalid. The same Boolean/raw-SQL root,
logical datatype, canonical date/UTC datetime, and null semantics apply as for fields.
Single table `?` and field `??` fail with marker-span diagnostics. Docs cannot
attach to checks. `resolved.Table.checks` owns ordered Check wrappers; emission
preflights every check before writing, then emits table CHECK items after columns
and any composite primary key with proper commas. Zero-column tables, including
literal checks-only tables, retain the existing non-executable skeleton policy;
unknown field references still fail resolution. Tests: `src/table_check_test.zig`,
`table_checks.sml`/SQL fixture, and `src/testdata/table_check_runtime_test.py`
(INSERT and UPDATE enforcement). Field-check coverage remains intact.

StoredFK Slice5 parses stored `*field Target?` (and `*!field Target`), resolves
single declared PK targets (including PK+FK chains) and inherited logical types,
and emits FK SQL. Field `#onDelete`
retains contextual identifier tokens, duplicates, and directive spans. Resolution
accepts only restrict/cascade/setNull after inherited types are ready; setNull
requires local nullability. Table/non-FK scope, duplicates, and unknown actions
are diagnosed. Emitter preflight rejects nonnullable set-null metadata.
PK+FK resolution is supported. Shared keys are nonnullable, never autogenerated,
and allow type-compatible defaults. Single integer PK+FK tables emit STRICT,
WITHOUT ROWID; composite and noninteger PK+FKs remain ordinary STRICT tables
with NOT NULL PK parts. `#allow reuse` is always invalid on FKs. `#onUpdate` is
unsupported. Automatic FK indexes are implemented: full indexes or keys with
leading FK columns cover the lookup; otherwise a deterministic ordinary index
is generated. Partial indexes do not cover it. See design §12,
`src/foreign_key_index_test.zig`, and `src/foreign_key_resolution_test.zig`,
`src/foreign_key_emission_test.zig`, and the Python runtime fixture.
VirtualRelationships Slice4 resolves direct collections (`~books Book[]
@Book.publisher`) after all columns/FKs and SQL names are finalized. Target/source
lookups use exact DSL names; source must equal target, and its stored FK must
reference the owner's single PK. The target itself may be keyless. Forward and
self mappings are supported. Virtual names collide only with exact DSL field or
relationship names, never normalized SQL identifiers. Centralized owned metadata
preserves docs/spans and table then relationship declaration order, without SQL
objects or documentation placement. Direct singular mappings require nullable
targets and a single-column uniqueness proof: PK, field/table UNIQUE, or full
unique index. Composite proofs and all partial indexes are rejected. Nullable
backing FKs are allowed. NamedConnections Slice3 adds endpoint mappings (below). Collections
must be nonnullable, including manually built parsed models; they need no unique
proof. Emitter preflight validates all public relationship bounds, exact DSL
names/collisions, owner FK mappings, and singular proofs before any writes,
using the same uniqueness helper as resolution (`src/unique.zig`). Invalid
metadata returns `InvalidRelationship`. Owned arenas clean up partial resolution
on OOM, including documented, SQL-renamed, forward/self singular mappings.
Slice4 documentation ownership and SQL neutrality integration is settled.
Relationship docs are preserved as owned text-only metadata, not discarded;
they do not emit SQL comments. No SQL placement convention has been chosen.
`src/relationship_integration_test.zig` compares independently parsed sources
with/without virtual declarations and their comments byte-for-byte, checks
interleaved declaration spans and resolved table/column indices after freeing
source and parsed storage, exercises all allocation failures and standard writer
failure/preflight ordering. The direct relationship SQL/runtime fixture covers
cross/self collections and singular mappings, named real UNIQUE constraints,
actual FKs, no virtual columns, and no redundant FK indexes. Existing EOF,
documentation detachment, forbidden options, and FK index coverage remain tested.
See `src/relationship_resolution_test.zig` for further ownership/OOM and mapping
coverage. SQL documentation placement is still open, not part of this settled
metadata-only implementation stage.
Other generators, JSON, timezone companions, and expression-index columns
remain unsupported. Date is implemented as described above.
Explicit unnamed connections support roles/self/multi-endpoints; shorthand matches exact pairs and generates only distinct-table pairs. Reusable types are deferred indefinitely.
Numeric exponent notation and multiline literals are deferred.

## Settled syntax

### Scopes, bodies, and whitespace

Tables require braces. Fields have two alternative body forms; the same forms
are proposed for indefinitely deferred reusable types:

```text
Author {
  name str =
    #name `display_name`

  age int {
    #name `years_old`
  }
}
```

- `=` introduces an indentation-based body. Direct body items must be indented
  exactly two spaces beyond the declaration's actual indentation; siblings match.
  Dedenting ends the body. The proposed `|` body form is not accepted.
- Braced scopes are indentation-independent. An `=` body inside braces still uses
  exactly two additional spaces relative to its own declaration.
- Tabs are forbidden in leading indentation, except inside literal content.
- Blank lines and ordinary comments do not establish or end indentation scope.
  They may appear before the first actual body item.
- A declaration cannot mix `=` and braced body forms.
- An indentation body can contain supported nested braced index/UNIQUE options:

  ```text
  name str =
    #index {
      #name `idx_name`
    }
  ```

- Index and constraint option bodies use braces only.
- A comment-only `=` body is allowed if its ordinary comment has the required
  indentation. A completely empty body is an error:

  ```text
  name str =
    -- TODO: add constraints.
  ```

  Comments are not retained in the parsed model unless they are docs.
- Declarations occupy separate lines; no semicolon separators or multiple
  declarations on one line.
- Opening braces stay on the declaration/option line. Closing braces occupy their
  own line, except empty `{}`, which is allowed.
- Multiline expressions require parentheses. Within those parentheses, line breaks
  are allowed and indentation is formatting only. This also permits a default's
  parentheses to span lines while its literal remains single-line.

The pipe-body experiment is superseded by `=` with exactly two additional spaces.
Braced bodies and all other settled rules remain unchanged.

### Comments and documentation

- `--` comments are source-only and can be standalone or inline.
- `---` documentation comments must be standalone.
- Consecutive doc lines form a block attached to the next declaration.
- A blank line breaks attachment; ordinary comments do not.
- Unattached documentation is an error, including doc-only bodies with no target.
- Docs can target tables, fields (including virtual relationships), reusable types,
  and connections. They cannot target directives or individual constraints.
- Remove one optional space immediately after `---`; preserve all remaining text
  and join doc lines with `\n`.
- Comment markers inside strings or raw SQL are literal content.

```text
--- Public author.
-- Internal note: this does not break attachment.
Author {
  --- Display name.
  name str = -- Omitted from generated SQL.
    #name `display_name`
}
```

### Identifiers and keywords

- Identifier grammar: `[A-Za-z_][A-Za-z0-9_]*`.
- Standalone `_` is reserved for the current-value expression placeholder.
- CamelCase and PascalCase are style conventions, not syntax requirements.
- Keywords are contextual except `true`, `false`, and `null`, which are reserved
  literals. For example, `str str` and `unique str` are valid field declarations.
- Exact SQL names use backtick literals and may contain broader characters.

### Numbers

Decimal integers and reals have an optional leading minus. Leading zeros are
allowed. A decimal point requires digits on both sides.

Accepted: `0`, `-12`, `001`, `1.25`, `-0.5`.

Not yet accepted: `.5`, `1.`, `+1`, `1e3`, hex, or digit separators.

The parser preserves original spelling. Numeric conversion, overflow, and
compatibility with the field type belong to resolution.

### Strings and backticks

- Ordinary strings use single quotes, SQL-style quote doubling, and literal
  backslashes. Double-quoted DSL strings are unsupported.
- Hash-delimited raw strings preserve content literally, with matching hash counts.
- Backticks have no escape syntax. Ordinary backticks close at the next backtick.
- Hash-delimited backticks allow embedded backticks:

  ```text
  #name #`foo`bar`#
  #name ##`contains `# safely`##
  ```

- Hash-delimited forms are supported wherever backticks are used: exact names,
  raw SQL, and enum text. Context determines meaning.
- Only an exact matching closing hash count terminates a hash-delimited literal;
  other delimiter-like sequences remain content. EOF without a matching closer
  is an error.
- Initial parser string and backtick literals are single-line. A newline before a
  matching closer is an error. Multiline raw strings remain a separate planned
  feature; their remaining rules must be settled before implementation.

## Parser API and ownership

Implemented API shape, following the resolver:

```text
parse(allocator, source) -> Allocator.Error!Result
Result = .schema OwnedSchema { schema, arena, deinit() } | .diagnostic { message, span }
```

- The parser owns arrays through an arena, exposed through a result with `deinit()`.
- Token text borrows the original source. The caller must retain that source until
  parsing and resolution have finished.
- Spans use zero-based, end-exclusive byte offsets, matching `parsed.Span`.
- Return the first syntax diagnostic with a clear message and source span.
- Return no partial schema on failure and reclaim all partial allocations.
- Allocation failures are separate from syntax diagnostics.
- Resolution keeps its existing fully owned result. After successful resolution,
  the parsed result and source can be freed.
- No multi-error recovery in the first implementation.
- Delivered source rendering lives in the public `diagnostics` module, separate
  from parsing/resolution. `formatParser` labels syntax errors; `formatResolver`
  uses semantic enum tags. The generic writer-based `format` accepts a byte span,
  message and optional category, with no allocator or combined compiler API.
- Display locations are one-based Unicode code-point columns, not byte offsets
  or terminal cell widths. Tabs render at four-column stops; excerpts and caret
  ranges are bounded and controls/malformed UTF-8 are escaped. CRLF is one break.
  Invalid spans return `InvalidSpan` before output; writer failures propagate.
  See the README Diagnostics contract for edge cases and examples. CLI design
  remains deferred.

## Implementation stages

Stages 1–4 below are the historical first-milestone plan, now delivered.
Stage 5 records subsequent delivered slices alongside explicitly deferred work;
use the status above and README for current support.

### 1. Model and literal groundwork

Extend `src/model/parsed.zig` to represent attached docs and their spans. Define
syntax diagnostics and the arena-owned parsed result without changing the borrowed
text contract. Preserve duplicate directives and original source spelling.

Rename the resolver's DSL built-in `text` to `str`, keeping SQLite `TEXT` storage
and internal text-value representations unchanged. Update the affected tests.
Update resolver backtick decoding for matching hash delimiters. Carry declaration
docs through the resolved model and emitter; do not silently discard them. Keep
semantic checks, SQL name conversion, default decoding, and reference lookup in
the resolver.

### 2. Tokenizer

Add `src/tokenizer.zig` with byte spans for identifiers, numbers, literals,
punctuation, comments, and newlines. Preserve line boundaries and leading-space
counts for indentation bodies, statement boundaries, and documentation rules.
Only `=` bodies use indentation for scope; braced scopes do not.

Scan literal content atomically so braces and comment markers inside
literals do not affect parsing. Distinguish raw-string prefixes from directives
and hash-delimited backticks. Reject unsupported multiline literals clearly.

### 3. Recursive-descent subset parser

Add `src/parser.zig`. Parse one complete file into the existing table/field model
with the documentation extension. Support alternate indentation-based `=` and
braced field bodies, nullable type references, defaults, and the modeled directives.

Use syntactic context to distinguish trailing nullable `?` from field-body check markers.
Track indentation only for active `=` bodies, not for braced or parenthesized
content. Never silently truncate input or ignore unknown syntax. Unknown type
names remain unresolved tokens.

### 4. Integration and testing

Export the parser from `src/root.zig`. Add tokenizer/parser tests and source-to-SQL
fixtures under `src/testdata/parser/`.

Test:

- Exactly two additional spaces for `=` items; mismatched siblings rejected.
- Dedenting, nested braced options, and blank lines/comments that preserve scope.
- Comment-only `=` bodies, rejected empty bodies, and mixed body forms.
- Rejected pipe-body syntax.
- Flexible indentation inside braces with relative `=` indentation; leading tabs rejected.
- Brace placement, empty bodies, and EOF in every incomplete construct.
- Doc blocks, blank-line separation, unsupported targets, and unattached docs.
- Nullable types, signed numbers, preserved leading zeros, and rejected exponents.
- Quote doubling, literal backslashes, and literal comment markers.
- Exact hash counts, embedded backticks, and unmatched delimiters.
- Multiline parenthesized defaults, with single-line literal content.
- Exact diagnostic spans and separate out-of-memory behavior.
- Cleanup under allocation failure and successful parse → resolve → emit.

Run `zig build test` and `zig fmt --check build.zig build.zig.zon src` after
implementation changes.

### 5. Later v1 feature slices (not part of this milestone)

Extend syntax models, parser, resolver, emitter, and tests together:

1. Date and inline enums are complete. JSON and additional generators remain
   unsupported; reusable types remain deferred indefinitely.
2. Nulls-equal remains deferred. Named expression CHECK bodies,
   ordinary/unique/partial indexes, composite uniqueness, expression precedence,
   field checks, and table checks are implemented; expression-index columns
   remain deferred pending grammar.
3. Stored FKs, automatic FK indexes, and direct virtual relationships are implemented.
4. NamedConnections Slice2 implements named connections, roles, and explicit
   composite PK FK keys. Endpoint target multisets are validated by a shared
   resolver/emitter helper. Repeated-table role bindings remain null; explicit
   key names/order do not imply roles. Slice3 adds `~name Target[]
   @Connection.source [<<destination]` and nullable singular `Target?` mappings.
   Both mapping fields are exact DSL names, not SQL aliases or header roles.
   Source must be an endpoint PK FK to the owner; a different destination key
   must reference the declared target. Infer only a single matching candidate;
   otherwise require an explicit hint or reject no match. Self/repeated-table
   endpoints work without any role-to-key naming convention. Collections retain
   tuples without implicit deduplication or ordering. Singular mappings require
   globally unique source alone (the existing single-column uniqueness helper).
   Owned relationship metadata stores the resolved destination index even when
   inferred; shared resolver/emitter validation rejects incomplete public metadata
   before SQL output. Direct destination hints are invalid. Tests cover forward
   names, SQL overrides, ambiguity, spans, whole-model preflight, runtime tuple
   semantics, and allocation failures. Slice4 adds byte-identical SQL comparisons
   with ordinary explicit FK tables, owned metadata after source/parsed teardown,
   full parse→resolve→emit OOM coverage, and runtime payload/default/constraint,
   custom-name deletion, explicit-key omission, and reverse-index coverage checks.
   Implemented explicit keys retain authored PK field order, not header order;
   keys are not prefilled without `~~`. Named `~~` generation and same-DSL-name
   overrides are implemented. Expansion uses resolver-owned arrays, preserves
   source metadata, and places keys in header order before source-ordered extras.
   Overrides retain stored-FK/PK/nonnullable/exact-endpoint roles and reject reuse;
   ordinary docs, names, actions, valid defaults, checks, uniques and indexes apply.
   Duplicate explicit names remain errors. Multi/self override pipelines have OOM,
   ownership and SQLite runtime coverage. Explicit unnamed declarations and
   `@.field` shorthand support exact pairs, including explicit role/self pairs.
   Unnamed identity is the sorted DSL table-name multiset, retaining repeats and
   excluding roles. Synthesized DSL/default SQL names join sorted table components
   with `__n__`; SQL normalizes each DSL component, ignoring parent SQL aliases.
   Shorthand uses canonical DSL identity, reuses explicit unnamed declarations
   even later in source, and never prefills keys without an explicit `~~` there.
   Otherwise exactly one generated connection per pair appends after authored
   tables, globally sorted by canonical identity. Opposite-side mappings share
   it; named connections remain distinct. Private arena-owned expansion copies
   bind relationship sources before key generation without mutating parsed input.
   Optional destination hints validate normally. Missing/unknown/composite PK
   endpoints and nested mappings are diagnosed; absent explicit self connections
   diagnose rather than guessing roles. Singular mappings still
   need a unique source. Fixtures cover SQL neutrality, ownership, OOM, tuple
   uniqueness, required keys, restrictive/cascading FKs and reverse indexes.
   Explicit unnamed self/role/multi-endpoint connections are implemented.
   Shorthand never selects a multi-endpoint connection by pair containment and
   implicit multi-endpoint connections are never guessed. Generated
   DSL key names concatenate `camelCase(table-or-role DSL name)` and
   `PascalCase(PK DSL field name)` (`Author.id` → `authorId`; role `writer` with
   `accountKey` → `writerAccountKey`); existing SQL normalization still applies.
   Named generated fields follow header endpoint order. Unnamed generated fields
   sort by exact table DSL name, then exact role DSL name for ties, using bytewise
   ASCII case-sensitive comparison rather than SQL names. Repeated tables still
   require distinct roles. Generated composite PKs follow generated field order;
   explicit keys keep authored order, and overrides do not move generated slots.
   Named casing removes underscores, uppercases the following byte, and changes
   only the initial byte otherwise (`URL` → `uRL`), preserving humps. Unnamed
   table/role sorting is implemented, including repeated tables. Role differences
   do not distinguish unnamed identities; duplicate identities are rejected.
   Explicit nested connection endpoints are implemented, including ordered
   composite FKs, generated component overrides and explicit tuple expansion.
   Dependency cycles and depth beyond 256 report invalid_connection.
   Composite-endpoint relationship mappings remain unsupported; implicit shorthand
   remains normal-endpoint-only.
5. Remaining directives and multiline literals after their rules are finalized.

Do not build a full-v1 parser ahead of models and semantic support.

## Follow-up decisions

This interview settled the high-level grammar, not every edge case. Resolve these
when implementing the affected features rather than inventing silent rules:

- Output placement for docs on reusable types or virtual relationships.
- Remaining multiline raw-string rules (tabs, blank marker lines, line endings).
- Enum literals in future DSL expressions (inline member/default grammar is settled).
- Remaining semantic and generated-SQL decisions listed in the v1 design.
