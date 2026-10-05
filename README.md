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
Unsupported later-v1 syntax returns a diagnostic.

`expression_parser.parse(allocator, source)` separately parses one literal,
ordinary identifier reference (`[A-Za-z_][A-Za-z0-9_]*`), or standalone `_`
current-value expression. `true`, `false`, and `null` remain literals; words
such as `str`, `unique`, and `now` are references here. The result is an owned
`.expression` or a `.diagnostic`; call `result.expression.deinit()` on success
and keep the source alive because token text borrows it. Surrounding blank lines
and ordinary comments are allowed, but docs and trailing expressions are not.
Parentheses may nest up to 256 levels and allow physical newlines and ordinary
comments inside; indentation there is only formatting (leading tabs still fail).
Bare line continuations, dotted names, hyphenated enum references, and operators
are not supported. References are not resolved, reusable types remain unsupported, and
this API does not extend schema defaults or constraints.

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
```

