# Parser plan

Status: the first supported parser milestone (stages 1–4) is implemented and
covered by tokenizer, parser, allocation-failure, and source-to-SQL tests.
Stage 5 is partially implemented through Slice18 partial indexes.
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
`unique(nulls: equal)`, named checks, and expression-index columns
remain deferred; expression-index grammar is unsettled. Unsupported syntax is diagnosed rather than ignored.
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
backticks are text, not SQL. NUL enum SQL uses quoted chunks plus `char(0)` to
preserve text in UTF-8/UTF-16; the older NUL `str` blob-cast default has a known
UTF-16 encoding bug (see design section 15). Tests: `src/enum_test.zig`, the
`enum.pzl`/SQL fixture, and `src/testdata/enum_runtime_test.py`.

Slice12 field checks are implemented end-to-end: `? expr` and `#check expr`
in both `=` and braced field bodies. The expression stream parser retains
original byte spans, nesting limits, and multiline trivia inside parentheses.
Trailing type `?` still means nullable. Docs cannot attach to checks.

Resolution waits for column metadata and final SQL names, then resolves each
check in field scope: `_` is the current field only; identifiers are forbidden.
Backtick raw SQL is trusted and may refer to other SQL names without placeholder
rewriting. Boolean (including nullable Boolean) or raw-SQL roots are required.
Resolved columns own an ordered `checks` expression array in the schema arena.
The emitter preflights all expressions and roots before any SQL; explicit checks
follow builtin enum/bool/datetime checks and preserve their source order.
`_ != null` emits `IS NOT NULL`; ordinary nullable comparisons retain SQL UNKNOWN.
Named check bodies and constraint names remain unsupported.
Tests: `src/check_test.zig`, `src/check_extra_test.zig`, `checks.pzl`/SQL fixture,
and `src/testdata/check_runtime_test.py`.

Slice13 table checks are implemented end-to-end: direct table `?? expr` and
`#check expr` can precede or follow fields. Parsed directives retain check payloads
and source order. Resolution runs after all columns are known, with
`expression_resolver.Context { .table = table, .field_index = null }`:
DSL names resolve to final SQL names (including quoted `#name` overrides),
forward references work, and `_` is invalid. The same Boolean/raw-SQL root,
logical datatype, canonical UTC datetime, and null semantics apply as for fields.
Single table `?` and field `??` fail with marker-span diagnostics. Docs cannot
attach to checks. `resolved.Table.checks` owns ordered expressions; emission
preflights every check before writing, then emits table CHECK items after columns
and any composite primary key with proper commas. Zero-column tables, including
literal checks-only tables, retain the existing non-executable skeleton policy;
unknown field references still fail resolution. Tests: `src/table_check_test.zig`,
`table_checks.pzl`/SQL fixture, and `src/testdata/table_check_runtime_test.py`
(INSERT and UPDATE enforcement). Field-check coverage remains intact.

Other generators, date/JSON, expression indexes, FKs, relationships, and
connections come in later slices. Reusable types are deferred indefinitely.
Numeric exponent notation and multiline literals are deferred.

## Settled syntax

### Scopes, bodies, and whitespace

Tables require braces. Fields and reusable types have two alternative body forms:

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
- An indentation body can contain nested braced options in later feature slices:

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

## Implementation stages

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

1. Additional defaults and date/JSON types. Inline enums are complete;
   reusable types remain deferred indefinitely.
2. Nulls-equal and named check bodies (ordinary/unique/partial indexes,
   composite uniqueness, expression precedence, field checks, and table checks
   are implemented; expression-index columns remain deferred pending grammar).
3. Stored FKs and virtual relationships.
4. Named/unnamed connections, roles, generated keys, and destination hints.
5. Remaining directives and multiline literals after their rules are finalized.

Do not build a full-v1 parser ahead of models and semantic support.

## Follow-up decisions

This interview settled the high-level grammar, not every edge case. Resolve these
when implementing the affected features rather than inventing silent rules:

- Output placement for docs on reusable types or virtual relationships.
- Remaining multiline raw-string rules (tabs, blank marker lines, line endings).
- Enum literals in future DSL expressions (inline member/default grammar is settled).
- Remaining semantic and generated-SQL decisions listed in the v1 design.
