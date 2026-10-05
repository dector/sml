# Parser plan

Status: settled interview decisions and implementation plan. No parser code has
been implemented yet. See [the language design](design-v1.md) for broader v1 scope.

## Goal and first milestone

Add source text → `parsed.Schema` to the existing resolver/emitter pipeline.
Implement the supported subset first, not the entire v1 language upfront.

The first milestone supports:

- Braced tables and stored fields.
- `!` primary-key markers, named type references, and nullable `?`.
- Defaults represented by the current parsed model: integers, reals, ordinary and
  raw text strings, null, and raw SQL.
- `#name` and field-level `#allow reuse`.
- Built-in string type `str`, emitted as SQLite `TEXT`; `text` and `string` are
  not DSL aliases. The current resolver's `text` spelling must be renamed during
  implementation; no resolver code has changed yet.
- Indentation-based `=` and braced field bodies.
- Source-only comments and preserved declaration documentation.
- Ordinary and hash-delimited backticks.

Unknown type names parse successfully; resolution reports unsupported/unknown
references. Recognizable unsupported syntax produces explicit diagnostics, not
silently ignored declarations. Booleans, generated defaults, reusable types,
enums, checks, indexes, FKs, relationships, and connections come in later slices.
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
  raw SQL, and later enum text. Context determines meaning.
- Only an exact matching closing hash count terminates a hash-delimited literal;
  other delimiter-like sequences remain content. EOF without a matching closer
  is an error.
- Initial parser string and backtick literals are single-line. A newline before a
  matching closer is an error. Multiline raw strings remain a separate planned
  feature; their remaining rules must be settled before implementation.

## Parser API and ownership

Recommended API shape, following the resolver:

```text
parse(allocator, source) -> Allocator.Error!Result
Result = parsed schema with owner | diagnostic
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

Use syntactic context to distinguish nullable `?` from future check markers.
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

### 5. Later v1 feature slices

Extend syntax models, parser, resolver, emitter, and tests together:

1. Reusable types, enums, and additional defaults.
2. Expression precedence, checks, uniqueness, and indexes.
3. Stored FKs and virtual relationships.
4. Named/unnamed connections, roles, generated keys, and destination hints.
5. Remaining directives and multiline literals after their rules are finalized.

Do not build a full-v1 parser ahead of models and semantic support.

## Follow-up decisions

This interview settled the high-level grammar, not every edge case. Resolve these
when implementing the affected features rather than inventing silent rules:

- Output placement for docs on reusable types or virtual relationships.
- Remaining multiline raw-string rules (tabs, blank marker lines, line endings).
- Enum bare-token grammar and enum literals in expressions.
- Remaining semantic and generated-SQL decisions listed in the v1 design.
