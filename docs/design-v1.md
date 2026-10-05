# SQLite-first DDL: v1 design

## 1. Purpose and status

A nicer data definition language for SQLite. It describes tables, types, constraints,
indexes, and relationships, and compiles them into fresh-schema SQLite SQL.

This document consolidates the design discussion. **Settled rules** are described
below. Where the discussion did not settle an implementation detail, it is listed
under **Open decisions** rather than silently made part of the language. See the
[parser implementation plan](parser-plan.md) for the settled initial-parser scope;
these syntax decisions require implementation updates, not just resolver changes.

### v1 scope

- One schema source file.
- SQLite **3.38+**, with JSON support available.
- `STRICT` tables by default.
- SQL output, not an ORM or query generator.
- Fresh-schema creation, not migrations.
- Stored foreign keys, backrefs, and generated connection tables are planned.
- Inline enums are implemented. Reusable types (including named enums) are
  deferred indefinitely; their examples below are design sketches, not supported syntax.
- Role-named and multi-endpoint connections are included toward the end of v1.
- No custom SQLite runtime functions required by generated constraints.

Older SQLite versions are not a supported v1 target. Documentation can explain
which features require newer SQLite, but the compiler does not promise an older
compatibility mode.

## 2. Syntax at a glance

```text
=> Status enum(draft) =
  #of draft, published, archived

--- A published work.
Book {
  !id int

  title str =
    ? ::notEmpty
    #index

  status Status =
    #use default

  *publisher Publisher?
  ~authors Author[] @Authorship.bookId

  createdAt datetime(::now)
  updatedAt datetime(::now) =
    #onUpdate ::now

  metadata json('{}')

  ?? title != ''
}

Publisher {
  !id int
  name str
  ~books Book[] @Book.publisher
}

Author {
  !id int
  name str
  ~books Book[] @Authorship.authorId
}

~Authorship(Author, Book) {
  ~~
  position int(0) =
    ? _ >= 0
}
```

`::notEmpty` illustrates the tool-generated constraint mechanism. Its exact
validation contract still needs to be specified; it is not a promise of a complete
v1 constraint catalog.

### Main symbols

| Syntax | Meaning |
| --- | --- |
| `Table { ... }` | Table declaration; braces are required |
| `field Type` | Stored field |
| `field Type(default)` | Stored field with a default |
| `Type?` | Nullable type |
| `!field` | Primary-key field/component |
| `*field` | Stored foreign-key field |
| `*!field` | Foreign key that is also a primary-key component |
| `~field` | Relationship, not a stored column |
| `@Table.field` | Relationship's source/matching field |
| `<<field` | Explicit destination endpoint in a connection |
| `~Name(A, B) { ... }` | Named connection table |
| `~(A, B) { ... }` | Unnamed connection table |
| `~~` | Expand generated connection keys |
| `=> Name Type` | Reusable type declaration; does not create a table |
| `declaration =` | Field/type body with direct items indented exactly two spaces beyond the declaration |
| `{ ... }` | Alternative braced body; cannot mix with an `=` body |
| `? rule` | Field/type constraint; shorthand for `#check rule` |
| `?? rule` | Table constraint; shorthand for `#check rule` |
| `_` | Current value in field/type DSL expressions |
| `::name` | Tool-generated constraint/default |
| `--` | Source-only comment |
| `---` | Doc comment, preserved in generated SQL |

Earlier exploratory forms such as `Author = {}`, `id: int`, `@auto`, `| default`,
`via`, `in`, relationship arrows, and `>`/`>>` constraint markers are **not** the
current syntax.

## 3. Scopes and whitespace

### Tables always use braces

```text
Author {
  !id int
  name str
}
```

A table never uses an `=` indentation body. Its opening `{` must be on
the declaration line and its closing `}` on its own line. Empty tables may use
`Table {}`. Connection tables follow the same brace rules.

### Fields and reusable types have two body forms

`=` with indentation:

```text
email str? =
  #name `email_address`
  ? unique
```

Braced:

```text
email str? {
  #name `email_address`
  ? unique
}
```

Use either `=` with an indented body or `{}`, **not both on the same declaration**.
A field without options needs no body:

```text
name str
active bool(true)
```

Each direct item in an `=` body must be indented exactly two spaces beyond the
declaration's actual indentation, regardless of its surrounding brace scope.
Sibling direct items must match that indentation; deeper indentation is allowed
only inside nested braced option bodies. A dedent to the declaration's indentation
or less, or the enclosing closing brace, ends the body. Other direct-item
indentation is an error. Blank lines and ordinary comments neither establish nor
end indentation scope. A body containing only a correctly indented `-- TODO`
comment is valid; a truly empty `=` body is an error.

Braced bodies have independent formatting: indentation does not establish their
scope or require a particular width. For every braced body, including fields,
reusable types, and index/constraint options, the opening `{` stays on the
declaration or option header line and the closing `}` occupies its own line.
Empty braced bodies may use `{}` on the header line. A declaration cannot mix an
`=` body with a braced body, though direct items may have nested braced options.

Index and constraint option bodies support braces only, never `=` bodies.

Declarations are order-independent. Resolve table and reusable-type references
after reading the whole file. Unknown references and circular reusable types are
compile errors.

Use one declaration per line; semicolon statement separators are unsupported.
Leading indentation tabs are forbidden except inside literal content. Space
indentation is formatting only in braced scopes, but establishes `=` body scope
with the exact two-space offset described above.

Expressions may span lines only inside parentheses; continuation indentation is
ignored. Strings and backtick literals are single-line in the initial parser.

## 4. Comments and documentation

```text
--- Public author information.
Author {
  --- Displayed beside a book title.
  name str

  -- Internal note; omit this from SQL output.
}
```

- `--` comments are source-only and may be standalone or inline.
- `---` doc comments must occupy standalone lines. Consecutive doc lines attach
  to the next declaration. Strip one optional space after each `---` and join
  their contents with newline characters.
- A blank line breaks doc attachment; ordinary comments preserve it. Unattached
  documentation is an error, including docs separated from their target by a
  blank line or left at the end of a scope.
- Doc targets are tables, fields (including relationships), reusable types, and
  connections, not directives or constraints.
- Attached docs are preserved as comments in generated SQL.
- Comment-looking characters inside strings and raw SQL are content, not DSL
  comments.
- Documentation attached to a `~` relationship is permitted even though the
  relationship has no column.

**Open detail:** output placement for docs attached to reusable types or virtual
relationships needs a convention; these declarations have no standalone SQL
object.

## 5. Names

### DSL names versus SQL names

DSL identifiers are ASCII: `[A-Za-z_][A-Za-z0-9_]*`. Standalone `_` is reserved
for the current-value expression, not a declaration name. `true`, `false`, and
`null` are reserved literals; other keywords are contextual.

Use camelCase for fields and PascalCase for tables/types. The compiler converts
DSL object names to snake_case SQL names by default:

```text
Invoice {
  tenantId int
  createdAt datetime
}
```

SQL names: `invoice`, `tenant_id`, `created_at`.

DSL references always use DSL names, not renamed SQL identifiers.

### Exact names with `#name`

`#name` names its **containing scope**, not the following declaration. Its argument
must always be enclosed in backticks and is an exact SQL name, with no case
conversion.

```text
Author {
  #name `people`

  !id int =
    #name `person_id`

  email str =
    #name `contact_address`
    ? unique {
      #name `uq_people_contact_address`
    }
}
```

This names the table `people`, the columns `person_id` and `contact_address`, and
the unique constraint `uq_people_contact_address`.

```text
#name `WriterID`
```

Preserves that capitalization. Neither unquoted values nor ordinary single-quoted
strings are accepted as `#name` arguments in v1.

Generated SQL always quotes identifiers and escapes identifier content safely.
Backticks in the DSL are delimiters, not instructions to emit SQLite backtick
quoting. Raw SQL fragments remain exact SQL and are not rewritten.

### Collisions

Reject duplicate SQL names in the applicable SQLite object namespace, including
collisions introduced by normalization or `#name`. SQLite identifier comparisons
are ASCII case-insensitive: exact names `WriterID` and `writerid` still collide.
Quoting identifiers preserves spelling but does not make those names distinct:

```text
Example {
  tenantId int
  tenant_id int  -- Both normalize to tenant_id: error.
}
```

Name conversion inserts an underscore before an uppercase letter following a
lowercase letter or digit, and at an acronym boundary before the final uppercase
letter followed by lowercase. Then ASCII letters are lowercased: `HTTPServer`
becomes `http_server`, `URLValue` becomes `url_value`, and `tenantId` becomes
`tenant_id`. Existing underscores are preserved.

**Open naming details:** generated index/trigger names and explicit naming of a
primary-key constraint need final rules. Hash-delimited backticks support embedded
backticks (see section 8) in the parser and resolver.

## 6. Built-in types and nullability

| DSL type | SQLite storage | Enforcement |
| --- | --- | --- |
| `int` | `INTEGER` | SQLite strict typing |
| `real` | `REAL` | SQLite strict typing |
| `str` | `TEXT` | SQLite strict typing |
| `blob` | `BLOB` | SQLite strict typing |
| `bool` | `INTEGER` | Value must be `0` or `1` |
| `date` | `TEXT` | Valid date in `YYYY-MM-DD` format |
| `datetime` | `TEXT` | Valid UTC timestamp in a fixed format |
| `json` | `TEXT` | `json_valid` |
| `enum` | `TEXT` | Allowed-value check |

The string built-in is `str`, not `text`; it maps to SQLite `TEXT`.
There are no initial aliases such as `text`, `string`, `float`, or `boolean`.

Fields are non-null unless their type ends in `?`:

```text
name str
nickname str?
active bool(true)
```

A default does not make a field nullable. Primary-key fields cannot be nullable.
Generated type validators must permit SQL null for nullable fields; a validator
that returns false for null needs an explicit null-allowing guard (see JSON).

`STRICT` mode allows SQLite's lossless type conversions; it does not mean that
all convertible input representations are rejected.

### Boolean example

```text
active bool(true)
```

```sql
"active" INTEGER NOT NULL DEFAULT 1
  CHECK ("active" IN (0, 1))
```

SQLite has no native boolean storage type. SQL `TRUE` and `FALSE` are aliases for
`1` and `0`. Boolean literal defaults accept only DSL `true` and `false`, not
numeric or string literals. Nullable Boolean fields may default to `null`.
The `IN` check yields SQL null for null input, so nullable fields permit null;
non-null fields enforce `NOT NULL` separately. Raw SQL defaults remain trusted
expressions whose results must satisfy these constraints at insertion.

Boolean fields cannot be primary keys, either alone or in composite keys.
This is a settled language rule, not a temporary limitation. Defaults do not
change this rule. `#allow reuse` is invalid for Boolean fields. The resolver and
emitter reject Boolean key membership; no Boolean `WITHOUT ROWID` SQL is emitted.

### Binary fields

```text
coverImage blob?
```

This stores binary data as SQLite `BLOB`, not JSON or encoded text. A dedicated
DSL binary-literal syntax has not been specified; raw SQLite defaults remain the
escape hatch.

### Arrays

In v1, `[]` is allowed only on `~` relationship collections:

```text
~books Book[] @.authorId
```

Stored arrays use JSON or a separate table:

```text
tags json('[]')
```

`tags str[]` is a compile error. Collection relationships are never nullable;
`Book[]?` is invalid.

## 7. Defaults

Parentheses after a type specify the field's default, not type parameters:

```text
count int(0)
price real(0)
active bool(true)
title str('Untitled')
nickname str?('Anonymous')
createdAt datetime(::now)
```

Numeric literals are decimal, with an optional leading minus. Leading zeros are
allowed. A fractional part requires digits on both sides of the decimal point.
Exponents, a leading plus, hexadecimal notation, and digit separators are not
supported yet.

Defaults apply when a column is omitted on insert, not when an explicit null is
supplied. An explicit null must satisfy the column's nullability.

**SQLite exception:** an ordinary `INTEGER PRIMARY KEY` (with or without
`AUTOINCREMENT`) treats an explicitly inserted null as a request to generate an
ID. Its stored key is still non-null. v1 preserves this SQLite behavior rather
than promising rejection of null input on these auto-generated keys. PK+FK tables
using `WITHOUT ROWID` do not have this exception.

```text
nickname str?(null)
```

Is allowed; a non-nullable field cannot have a null default.

Raw SQL defaults use backticks inside the default parentheses:

```text
createdAt datetime(`strftime('%Y-%m-%dT%H:%M:%SZ','now')`)
```

The compiler adds whatever surrounding SQL syntax SQLite requires for a default
expression, without rewriting the expression's contents.

Literal defaults must match their types. Enum defaults must be declared enum
values. Runtime SQL defaults cannot generally be proven valid at compile time;
the resulting value must satisfy the SQLite column constraints when used.

### Tool-generated defaults

```text
createdAt datetime(::now)
```

`::now` is the only supported generator and is valid only in datetime defaults.
It emits `strftime('%Y-%m-%dT%H:%M:%SZ','now')`, producing the current UTC timestamp
at whole-second precision. It is computed by SQLite on insertion, not by the
compiler or application. It does not refresh a timestamp on update by itself.

### Defaults on integer primary keys

Normal single-column integer primary keys generate IDs automatically. They cannot
also specify a default or `#use default`:

```text
!id int(100)  -- Error.
```

## 8. Strings

### Ordinary strings

Ordinary strings use single quotes:

```text
title str('Untitled')
metadata json('{}')
```

Double-quoted DSL strings are not supported. Quotes occurring inside raw SQL are
SQLite syntax and are unaffected by this rule.

An embedded single quote is written as two single quotes (SQL-style doubling):
`'It''s ready'` decodes to `It's ready`. Backslashes are literal, not escapes;
`'C:\books'` preserves its backslash. Raw strings are another way to include
quotes and backslashes literally.

### Raw strings

```text
message str(#'She said "it's ready"'#)
path str(#'C:\books'#)
```

`#'...'#` uses matching delimiters `#'` and `'#`.
Contents are literal; quotes and backslashes need no escaping.

Use more matching hashes if the content contains the closing delimiter:

```text
message str(##'This contains '# safely'##)
```

The opening and closing hash counts must match.

### Backtick literals

Backticks contain exact SQL expressions, exact SQL names, or enum text according
to context. They may use hash delimiters to include embedded backticks:

```text
#name #`foo`bar`#
```

Multiple hashes are allowed. Only a backtick followed by exactly the opening
hash count closes the literal; other hash runs are content. This rule applies in
all backtick contexts, not only SQL names. Backticks, like strings, must remain
on one line in the initial parser.

### Deferred multiline raw strings

The following is an aspirational feature, not initial-parser syntax. All ordinary
and raw strings are initially single-line; multiline support is deferred.

Multiline raw strings use triple single quotes, with the hash-delimited raw-string
form. The opening and closing delimiter lines contain no content apart from their
delimiters and the optional opening modifier.

Delimiter-only lines are excluded from the value. Interior line breaks and blank
lines remain part of the string.

#### Default: dedent

```text
#'''
    Foo
      Bar
'''#
```

Remove the largest common space prefix from nonblank lines. Result:

```text
Foo
  Bar
```

Do not independently strip every line: relative indentation must be preserved.

#### `+`: preserve spaces

```text
#'''+
    Foo
      Bar
'''#
```

Keep interior whitespace exactly.

#### `|` or `>`: line-start marker

```text
#'''|
    |Foo
  | Bar
'''#
```

Strip spaces before the marker and the marker itself. Preserve everything after
it. Result:

```text
Foo
 Bar
```

`>` has the same behavior, with `>` as the marker:

```text
#'''>
    >Foo
    >  Bar
'''#
```

Produces `Foo` followed by a line containing two spaces before `Bar`. Neither
modifier folds line breaks. Only `|` and `>` are line-start marker choices.

Within a field default, keep the delimiter lines separate from the surrounding
parentheses:

```text
description str(
  #'''
    First paragraph.

    Second paragraph.
  '''#
)
```

**Open details:** treatment of markerless blank lines, tabs during dedenting, and
line-ending normalization need final rules. A nonblank line missing its requested
line-start marker should be reported rather than silently changed (recommended
validation rule).

## 9. Primary keys and automatic IDs

### Single-column integer keys

```text
Book {
  !id int
}
```

```sql
CREATE TABLE "book" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;
```

`!` declares the key; ordinary single-column integer keys automatically generate
IDs. There is no `@auto` in the current design.

By default, use SQLite `AUTOINCREMENT`: previously committed generated row IDs
are not reused. This does **not** guarantee gapless numbering, and does not forbid
explicit inserts of previously used IDs.

### Allow reuse

```text
!id int =
  #allow reuse
```

Generates `INTEGER PRIMARY KEY` without `AUTOINCREMENT`. SQLite still generates
IDs, but may reuse a deleted ID, particularly a deleted highest ID.

`#allow reuse` is only valid for an ordinary single-column integer primary key,
not a non-key field, a non-integer key, a composite key, or a PK+FK. `reuse` is the
only supported `#allow` option in v1.

### Composite keys

```text
ReadingProgress {
  *!reader Reader
  *!book Book
  page int(0)
}
```

Multiple `!` fields form one composite primary key. Neither component is
individually unique. Composite keys do not get automatic ID generation; every
component is non-null.

### Keyless tables

Keyless tables are allowed. Ordinary SQLite tables have a hidden `rowid`, but it
is not a declared schema key and is not an FK target. `VACUUM` can change a hidden
rowid that is not aliased by an `INTEGER PRIMARY KEY` column.

For v1, FK targets must have a declared single-column primary key. Composite FK
targets and references to alternative unique keys are outside the settled v1
reference syntax.

### Shared identity: PK+FK

```text
User {
  !id int
}

UserSettings {
  *!user User =
    #onDelete cascade

  darkMode bool(false)
}
```

PK+FK fields do not generate IDs automatically. They refer to an existing parent
identity. A single-column integer PK+FK uses `WITHOUT ROWID` to prevent SQLite's
implicit integer-key assignment:

```sql
CREATE TABLE "user_settings" (
  "user" INTEGER NOT NULL PRIMARY KEY
    REFERENCES "user" ("id") ON DELETE CASCADE,
  "dark_mode" INTEGER NOT NULL DEFAULT 0
    CHECK ("dark_mode" IN (0, 1))
) STRICT, WITHOUT ROWID;
```

This allows at most one settings row per user, without a redundant settings ID.
It does not require every user to have settings. Omitting `user` fails instead of
generating a potentially unrelated parent ID.

The language does not yet expose a general-purpose `WITHOUT ROWID` directive.
Its use for other table shapes is an implementation decision to document later.

## 10. Constraints and expressions

### `#check` and its shortcuts

Field/type scope:

```text
price real =
  ? _ > 0
```

Equivalent:

```text
price real =
  #check _ > 0
```

Table scope:

```text
Booking {
  startsAt datetime
  endsAt datetime

  ?? endsAt > startsAt
}
```

Equivalent:

```text
#check endsAt > startsAt
```

- `?` is valid only in field/type bodies.
- `??` is valid only directly in table bodies.
- `#check` works in either scope.
- Wrong-scope shortcuts are compile errors.
- Table constraints can appear anywhere directly inside the table; placing them
  at the bottom is a style convention.

The trailing `?` in `str?` is nullability, not a constraint marker.

### DSL expressions

v1 supports:

- Comparisons: `==`, `!=`, `<`, `<=`, `>`, `>=`.
- Logical operators: `&&`, `||`, `!`.
- Parentheses.
- Literals and references appropriate to the expression's scope.

```text
? _ >= 1 && _ <= 5
?? endsAt > startsAt
?? !(email == null && phone == null)
```

Precedence, highest first: `!`, comparisons, `&&`, `||`. Parentheses override it.
Arithmetic and a general expression-function language are not part of the
settled v1 subset; raw SQL covers more complex expressions.

Field/type expressions use `_` for their current value. Cross-field DSL checks
belong at table scope and use DSL field names. `_` is invalid at table scope.

The compiler resolves DSL names to quoted SQL identifiers, including any `#name`
overrides:

```text
Booking {
  startsAt datetime
  endsAt datetime
  ?? endsAt > startsAt
}
```

```sql
CHECK ("ends_at" > "starts_at")
```

### Null comparisons

```text
?? email != null || phone != null
```

Compiles to:

```sql
CHECK ("email" IS NOT NULL OR "phone" IS NOT NULL)
```

- DSL `== null` means SQL `IS NULL`.
- DSL `!= null` means SQL `IS NOT NULL`.
- Do not compile either into ordinary SQL equality against `NULL`.

### SQLite CHECK semantics

A SQL `CHECK` rejects a row when its expression evaluates to zero/false. A null
result passes. Column `NOT NULL` is enforced separately.

```text
price real? =
  ? _ > 0
```

Accepts null and positive values, but rejects zero and negative values.

```text
price real =
  ? _ > 0
```

Rejects null because the column is non-nullable.

To explicitly reject null in a nullable field's check:

```text
? _ != null && _ > 0
```

### Exact raw SQL

Backticks introduce exact SQL in an expression context:

```text
price real =
  ? `price > 0`
```

```text
?? `ends_at > starts_at`
```

Raw SQL uses actual SQL names, not DSL names. It is not identifier-rewritten or
placeholder-expanded. Neither `_` nor `VALUE` means the current field inside raw
SQL. If the SQL name changes, the user must update any affected raw fragments.

Raw SQL constraints are not limited to the DSL expression subset, but SQLite's
own `CHECK` restrictions still apply (for example, no subqueries). Field-level
raw SQL is not restricted by the DSL's own-value-only rule.

### Native versus tool-generated rules

```text
email str? =
  ? unique
  ? ::isEmail
```

- `unique` is a native schema constraint.
- `::isEmail` requests tool-generated SQLite enforcement.
- `::` does not simply mean a stdlib import.
- Every constraint must be enforced by SQLite.
- Unsupported constraints cause compile errors, not silent application-side
  validation or omitted checks.
- Generated constraints must use built-in SQLite features. No hidden UDF
  registration requirement is allowed in v1.

SQLite has no built-in comprehensive email validator. The supported `::`
constraint catalog and each validator's exact strength remain open decisions.
A simple heuristic must not be advertised as full email validation.

### Constraint names

```text
email str =
  ? unique {
    #name `uq_reader_email`
  }
```

```text
?? unique(country, username) {
  #name `uq_country_username`
}
```

`#name` in this options scope names the constraint, not the field/table. `as` naming
is deferred. Native `unique` emits a uniqueness constraint/index, not a SQL `CHECK`.

## 11. Uniqueness

### Individual fields

```text
email str =
  ? unique
```

### Composite uniqueness

```text
Reader {
  country str
  username str

  ?? unique(country, username)
}
```

The pair is unique; neither field must be unique on its own. Adding a field-level
`? unique` would impose an additional, stronger requirement.

### Nulls

Plain `unique` follows SQLite: multiple nulls are allowed.

```text
email str? =
  ? unique
```

To allow only one null:

```text
email str? =
  ? unique(nulls: equal)
```

SQLite has no direct `NULLS NOT DISTINCT` declaration. The single-column behavior
can be enforced with a normal unique index plus a unique partial constant index:

```sql
CREATE UNIQUE INDEX "reader_email_unique"
  ON "reader" ("email");

CREATE UNIQUE INDEX "reader_email_one_null"
  ON "reader" ((1)) WHERE "email" IS NULL;
```

The second index gives every null row the same indexed value, prohibiting a second
one. This is a compiler-generated enforcement mechanism, not a runtime check.

**Open detail:** nulls-equal behavior and syntax for composite uniqueness were not
settled. Custom names for a rule that expands into several physical SQL objects
also need a deterministic naming convention.

## 12. Foreign keys and deletion behavior

```text
Book {
  !id int
  *publisher Publisher?
}

Publisher {
  !id int
}
```

`*publisher` is a stored column in `Book`. It references `Publisher`'s declared
single-column primary key and inherits its storage type. The stored column's
name is `publisher` unless overridden; `*` does not itself append an `Id` suffix.
Use `*publisherId Publisher?` when that is the desired DSL/SQL naming convention.

### Deletion actions

Default: `restrict`.

```text
*owner Reader =
  #onDelete cascade
```

```text
*editor Reader? {
  #onDelete setNull
}
```

Settled actions:

- `restrict`: reject deleting a referenced parent.
- `cascade`: delete dependent rows.
- `setNull`: null the FK; requires a nullable field.

`setNull` is incompatible with a PK+FK because primary keys are non-null.
Additional SQLite actions and FK update-action syntax have not been designed.
The timestamp directive `#onUpdate ::now` is not an agreed FK update-action syntax.

### Enforcement setup

Generated SQL includes:

```sql
PRAGMA foreign_keys = ON;
```

Run this before starting a transaction. FK enforcement is a **per-connection**
setting, not persistent schema configuration. Applications opening additional
connections must enable it too. v1 does not generate runtime connection helpers.

### Automatic indexes

Index FK columns automatically, unless an existing index already has the FK
columns as its leading columns. Do not generate redundant indexes.

For a connection primary key `(authorId, bookId)`, its index covers `authorId`;
`bookId` needs a separate index for reverse lookups.

Implementation must account for coverage accurately: a partial index does not
necessarily cover all FK rows. Index ordering matters.

### Self-FKs

```text
Category {
  !id int
  *parent Category?
  ~children Category[] @Category.parent
}
```

Self-FKs are supported. They enforce existence, not acyclicity. Preventing cycles
is not an implicit language feature.

Composite foreign keys are deferred beyond v1. Multiple independent FKs are not
a substitute for a composite FK when a tuple must reference one parent row.

## 13. Relationships and backrefs

### Stored versus virtual

```text
*profile Profile?
~author Author? @Author.profile
```

- `*` stores a column in the current table.
- `~` never stores a column in the current table.
- `@` identifies the backing matching field elsewhere.
- These are metadata/schema declarations, not automatically loaded values.

Every `~` relationship supplies a source mapping. The earlier `in`, `via`, and
arrow mapping forms have been replaced by `@`.

### One-to-many

```text
Publisher {
  !id int
  ~books Book[] @Book.publisher
}

Book {
  !id int
  *publisher Publisher
}
```

`Book.publisher` is the FK matching the current publisher's primary key. No
connection table is created. The collection can have zero matches and is not
nullable.

### One-to-one

```text
Author {
  !id int

  *profile Profile? =
    ? unique
}

Profile {
  !id int
  ~author Author? @Author.profile
}
```

A unique stored FK ensures at most one author references a given profile. A
singular backref requires its source FK to be unique or a primary key; otherwise
compilation fails.

Singular backrefs must be nullable in v1. A required forward FK guarantees every
referencing row has a target, but does not guarantee every target has a referring
row. Reverse-side existence enforcement is not part of v1.

### Forbidden column options

`~` relationships cannot have defaults, `#name`, `#index`, or field constraints.
Configure the backing FK or connection table instead. A virtual relationship has
no SQL column to name, index, or constrain.

## 14. Connection tables

### Implicit unnamed connections

```text
Author {
  !id int
  ~books Book[] @.authorId
}

Book {
  !id int
}
```

The `@.authorId` shorthand uses the unnamed connection between the current table
and the relationship's target. Resolve it by the canonical, order-independent
endpoint pair:

- If an explicit `~(Author, Book)` declaration exists, reuse that connection and
  its fields/options; do not generate another table.
- Otherwise, generate the default connection.
- Opposite-side shorthand references resolve to the same connection.
- Named connections are selected explicitly, such as `@Authorship.authorId`.

For a generated default connection, create a table such as `author__n__book` with:

```text
*!authorId Author
*!bookId Book
```

Both fields are non-null and form one composite primary key, preventing duplicate
pairs. Their types come from the referenced primary keys. FK deletion defaults
remain `restrict`, not implicit cascade.

Default generated key names are `<table-or-role><primary-key-field>` in camelCase,
for example `authorId`. SQL normalization produces `author_id`. The discussion
settled the `id` examples; exact casing rules for other key names remain to be
specified.

### Explicit unnamed declaration

```text
~(Author, Book) {
  ~~
  role str('author')
  addedAt datetime(::now)
}
```

The header identifies the connected tables; `~~` explicitly fills in their
standard key fields. Extra fields extend the connection.

Users may write out the keys instead:

```text
~(Author, Book) {
  *!authorId Author
  *!bookId Book
  role str('author')
}
```

`~~` and explicit keys are alternative ways to supply the standard fields. Do
not silently prefill keys in an explicit declaration lacking both `~~` and
explicit key declarations.

### Named connections

```text
~Authorship(Author, Book) {
  ~~
  position int(0)
}

~Translation(Author, Book) {
  ~~
  language str
}
```

References:

```text
~writtenBooks Book[] @Authorship.authorId
~translatedBooks Book[] @Translation.authorId
```

Names distinguish multiple relationships between the same tables. The generated
SQL names default to `authorship` and `translation`; `#name` can override them.

### Customize generated fields

```text
~Authorship(Author, Book) {
  #name `book_credits`
  ~~

  *!authorId Author =
    #name `writer_id`
    #onDelete cascade

  position int(0)
}
```

The explicit `authorId` enriches/overrides the matching generated field; it is not
a duplicate column. `bookId` retains its generated defaults.

Overrides match by **DSL field name**, not SQL name. They preserve the generated
field's structural role: non-null FK to the same endpoint, and a component of the
connection's composite primary key. Names and FK options can change.

### Identity and ordering

Unnamed connection identity is order-independent:

```text
~(Author, Book)
~(Book, Author)
```

These identify the same connection, not two different tables. Declaring both is
a duplicate-definition error. Use deterministic naming such as
`author__n__book`. Named connections are distinct by their declared names.

Connection identity being order-independent does not make composite index order
irrelevant. **Open detail:** define one consistent generated key ordering rule;
the conversation did not choose the exact canonical ordering algorithm.

### Role names

Roles customize generated DSL key names:

```text
~Authorship(writer Author, publication Book) {
  ~~
}
```

Generates `writerId` and `publicationId`, rather than `authorId` and `bookId`.

### Self-connections

```text
~Following(follower Reader, followed Reader) {
  ~~
  createdAt datetime(::now)
}

Reader {
  !id int
  ~following Reader[] @Following.followerId
  ~followers Reader[] @Following.followedId
}
```

Roles resolve the otherwise duplicate `readerId` keys. The mapped field is the
current reader's side; the other endpoint supplies related readers.

### More than two endpoints

Connections can have two or more endpoints:

```text
~Permission(user User, resource Resource, role Role) {
  ~~
}
```

Generates:

```text
*!userId User
*!resourceId Resource
*!roleId Role
```

The triple forms one composite primary key. The same user/resource pair can
occur with multiple roles.

### Explicit destination hints

If exactly one other endpoint matches the requested type, infer it. Otherwise,
require `<<destinationField`:

```text
~ReviewAssignment(author Reader, reviewer Reader, approver Reader) {
  ~~
}

Reader {
  !id int

  ~reviewers Reader[] @ReviewAssignment.authorId <<reviewerId
  ~approvers Reader[] @ReviewAssignment.authorId <<approverId
}
```

For a connection row `(authorId: 1, reviewerId: 2, approverId: 3)`, reader `1`
relates to reviewer `2` through the first mapping and approver `3` through the
second.

- `@ReviewAssignment.authorId` matches the current model's primary key.
- `<<reviewerId` selects the FK identifying related data.
- Both selectors use DSL field names.
- Validate that the source references the current table and the destination
  references the declared relationship type.
- Do not infer a destination from a collection's name such as `reviewers`.
- Missing or ambiguous endpoints are compile errors.

`<<` is optional when there is only one possible destination. It is not a
bit-shift operator in the v1 expression language.

Multi-endpoint connections can contain multiple tuples leading to the same
related record. v1 generates no queries and makes no implicit promise of runtime
collection deduplication or ordering.

## 15. Enums

### Inline enums

```text
status enum(draft) =
  #of draft, published, in_review
  #of out-of-print, `in review`
```

Inline enums are implemented end-to-end, with both `=` and braced field bodies.

- `#of` is field-only and enum-only. Commas separate members on each line.
  Missing members and trailing commas are errors; lists do not continue on the
  next line. Multiple `#of` lines accumulate values in source order.
- Bare values match `[A-Za-z_][A-Za-z0-9_-]*` with maximal matching. Declaration
  identifiers remain `[A-Za-z_][A-Za-z0-9_]*`.
- In enum-value contexts, `a--b` is one value, not a comment. Put whitespace
  before `--` to start a comment after a bare value: `#of a -- comment`.
  Existing adjacent comments such as `field str--comment` are unchanged.
- `true`, `false`, and `_` are valid bare enum text contextually. Bare `null` is
  reserved for a nullable default; use `` `null` `` for the actual text.
- Backticks (including hash-delimited backticks) represent arbitrary valid UTF-8
  text, never raw SQL in `#of` or an enum default. NUL is allowed; malformed UTF-8
  is rejected by resolution and direct emitter validation. Literal scanning
  remains atomic.
- Empty backtick text is a valid member. Empty allowed sets are errors.
- Duplicate decoded values are errors, including duplicates across `#of` lines
  or different delimiter forms. Comparison is exact bytes, with no case folding
  or Unicode normalization.
- Enum defaults must be declared members, or `null` on a nullable enum. Ordinary
  strings, numbers, and `::now` are invalid enum defaults.
- SQL uses `TEXT` with `CHECK (column IN (...))`. Values are safely quoted;
  apostrophes are doubled. NUL text uses quoted pieces joined with `char(0)` so
  Unicode and NUL round-trip in UTF-8 and UTF-16 databases. Nullable SQL NULL
  passes the check; non-null fields have a separate `NOT NULL`.
- Enum primary keys use ordinary TEXT semantics, including composite keys; they
  do not generate IDs. Nullable keys are invalid. `#allow reuse` remains single
  integer-primary-key-only. Stored arrays remain unsupported.
- Resolver validation also covers manually constructed parsed enums. Emitter
  validation covers direct resolved metadata and literal default membership
  before any output. Direct resolved `.raw_sql` defaults remain a trusted
  escape hatch, like other columns, and face the runtime CHECK on insertion.

Enum defaults are bare enum values:

```text
status enum(published) =
  #of draft, published
```

For defaults containing spaces:

```text
status enum(`in review`) =
  #of draft, `in review`
```

Do not require single quotes around enum defaults. Ordinary `str` defaults still
use string literals.

### Reusable enums (deferred indefinitely)

The following is a design sketch only. Reusable type declarations are unsupported.

```text
=> Status enum(draft) =
  #of draft, published, archived
```

Or:

```text
=> Status enum(draft) {
  #of draft, published, archived
}
```

This declares a type, not a table. Fields use the plain type name:

```text
status Status(published)
```

Store the exact enum text in `TEXT` and generate a check per field:

```sql
"status" TEXT NOT NULL DEFAULT 'published'
  CHECK ("status" IN ('draft', 'published', 'archived'))
```

No lookup table or numeric ordinal mapping is generated. Reordering enum values
does not change stored meaning.

A default outside the declared values is a compile error. A null default is
allowed only for a nullable enum.

Fields using a named enum cannot add values with `#of`. They may narrow the type
with additional checks, but cannot expand it.

Enum values and ordinary text defaults share encoding-independent SQL quoting.
NUL-containing text uses `char(0)` concatenation, preserving it in both UTF-8 and
UTF-16 databases rather than casting encoding-dependent blob bytes to text.

## 16. Reusable constrained types (deferred indefinitely)

This section is a design sketch; none of this syntax is currently supported.

```text
=> Positive int =
  ? _ > 0

=> Rating Positive =
  ? _ <= 5

Review {
  rating Rating(3)
}
```

`=>` marks a reusable type declaration. It creates no standalone SQL table or
custom SQLite type. Resolve it to its underlying storage type and accumulate its
constraints on each using column.

Fields may add checks, but cannot remove inherited guarantees:

```text
Review {
  rating Rating(3) =
    ? _ >= 2
}
```

This field allows `2` through `5`. Type composition is allowed; cycles are compile
errors.

### Defaults are opt-in

```text
=> Status enum(draft) =
  #of draft, published, archived

Book {
  -- No default.
  status Status

  -- Inherit the type's default: draft.
  initialStatus Status =
    #use default

  -- Explicit field default.
  previousStatus Status(archived)
}
```

Constraints inherit automatically; defaults do not. A reusable type built on
another type must likewise opt in with `#use default` to inherit its default.

Compile errors:

- An explicit default together with `#use default`.
- `#use default` when the referenced type has no default.
- An inherited default incompatible with the final field type/nullability.

Raw SQL checks remain exact SQL even inside reusable type definitions. They are
not portable placeholders; use `_` in DSL expressions for column-independent
checks.

## 17. Indexes

### Field index

```text
title str =
  #index
```

### Table/composite index

```text
#index publisherId, publishedAt
```

The listed order is the indexed column order.

### Named index

```text
#index publisherId, publishedAt {
  #name `idx_book_publication`
}
```

At field scope:

```text
title str =
  #index {
    #name `idx_book_title`
  }
```

Index option scopes require braces. No `as` naming or `#index =` form is supported.

### Partial indexes

```text
#index title {
  #name `idx_active_titles`
  #where deletedAt == null
}
```

`#where` accepts DSL row expressions using field names or exact raw SQL:

```text
#where `deleted_at IS NULL`
```

SQLite's own partial-index restrictions still apply. For example, predicates
cannot depend on subqueries or nondeterministic functions.

### Unique partial indexes

```text
#index email {
  #unique
  #where deletedAt == null
}
```

Only indexed rows participate in uniqueness. This can enforce unique emails among
active rows while permitting duplicates among deleted rows.

`#index` is separate from `#check`: indexes are not validation checks. `#unique`
is an index option; native `? unique` remains available for ordinary uniqueness.

## 18. Dates, timestamps, and timezones

### Date

```text
birthDate date
```

Store validated `YYYY-MM-DD` text. No timezone is attached to a date.

### Datetime

```text
createdAt datetime(::now)
```

The implemented datetime slice accepts exactly `YYYY-MM-DDTHH:MM:SSZ`:

```text
2026-07-17T10:30:00Z
```

Explicit slice rules: years `0001`–`9999`, real proleptic Gregorian calendar
dates (including century leap-year rules), hours `00`–`23`, minutes and seconds
`00`–`59`. UTC uppercase `Z` only. No offsets, leap seconds, or fractional seconds
(including `.000`). Fractional precision is a later feature.

Ordinary/raw string defaults are decoded and validated during resolution.
`::now` is contextual default syntax, supported only for datetime, and emits
`DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))`. No other generator is supported.
Raw SQL defaults remain an escape hatch but must satisfy runtime checks.

Datetime retains logical identity and uses SQLite `TEXT` in strict tables, with
explicit format, range, and calendar CHECK constraints, not permissive SQLite
date functions. Nullable NULL passes; nonnullable NULL fails. Datetime primary
keys never generate integer IDs; `#allow reuse` is integer-only.
Fixed-format UTC text sorts chronologically. Reusable types remain indefinitely
deferred; date, JSON, enums, and update generators are not part of this slice.

### Companion timezone field

```text
Event {
  startsAt datetime =
    #tz eventTimezone

  endsAt datetime =
    #tz eventTimezone
}
```

`eventTimezone` is a **DSL field name**, not a timezone value. If absent, generate
one shared non-null `str` field defaulting to `'UTC'`. Both datetimes link to it.

Users can explicitly declare the field:

```text
Event {
  eventTimezone str('Europe/Berlin') =
    #name `event_timezone`

  startsAt datetime =
    #tz eventTimezone

  endsAt datetime =
    #tz eventTimezone
}
```

Declaration order does not matter. Reuse the existing compatible field rather
than generating a duplicate. Incompatible field types are compile errors.

The timezone is intended to hold an IANA name, not merely a numeric offset. SQLite
has no built-in IANA timezone conversion. v1 only creates the companion field and
stores UTC datetimes; applications handle conversion. Do not promise SQLite-side
validation against the full IANA database.

**Open detail:** the exact compatibility rules for explicitly declared timezone
fields, including nullable fields and constrained `str` aliases, need finalization.

### Automatic update timestamps

```text
updatedAt datetime(::now) =
  #onUpdate ::now
```

- `::now` gives the insertion default.
- `#onUpdate ::now` generates a SQLite trigger.
- If an update changes the timestamp explicitly, preserve that value.
- If the timestamp is unchanged, refresh it automatically.
- SQLite cannot distinguish omission from explicitly assigning the existing
  value; both count as unchanged.

This behavior is based on value changes, not knowing which assignments the user
wrote. v1 has no generated application hook.

**Trigger implementation requirements:** avoid recursive refresh loops, including
when two timestamps have the same second value; support composite and keyless
tables appropriately; use null-safe old/new comparisons. The exact trigger SQL
and behavior for no-op updates remain implementation details to settle and test.

## 19. JSON in v1

SQLite has JSON functions, not a native `JSON` column type accepted by `STRICT`
tables. Our `json` type compiles to validated `TEXT`:

```text
metadata json
settings json('{}')
tags json('[]')
```

```sql
"settings" TEXT NOT NULL DEFAULT '{}'
  CHECK (json_valid("settings"))
```

For a nullable field:

```text
settings json?
```

```sql
"settings" TEXT
  CHECK ("settings" IS NULL OR json_valid("settings"))
```

At the SQLite 3.38 baseline, `json_valid(NULL)` returns zero; newer versions
(such as 3.50.2) return null. The explicit guard permits SQL null consistently
across supported versions instead of relying on the function's null behavior.
JSON text `'null'` is also valid JSON, but is distinct from SQL null.

The baseline behavior is visible in SQLite's
[3.38 JSON implementation](https://github.com/sqlite/sqlite/blob/version-3.38.0/src/json.c)
(`jsonValidFunc`).

Validate JSON literal defaults at compile time. Runtime values are checked by
SQLite. JSONB/BLOB storage is not the v1 default.

### Deferred structured literals

These are **not supported in v1**:

```text
settings json({})
tags json([])
settings json({theme: 'dark'})
```

The future structured-literal design discussed:

- Bare object keys represent strings.
- String values require string literals; bare `bar` is not a string value.
- Numeric, boolean, and null values retain JSON meanings.
- Duplicate object keys are compile errors.

That parser and its duplicate-key rule are deferred. The conversation did not
settle duplicate-key rejection for JSON supplied as a v1 string literal; SQLite's
`json_valid` alone does not establish that policy.

## 20. Compiler behavior and diagnostics

### Required behavior

- Parse one complete source file before resolving references.
- Expand reusable types, connection keys, and companion timezone fields.
- Keep DSL identifiers distinct from final SQL identifiers.
- Detect normalization/override collisions before emitting SQL.
- Validate relationship endpoints and singular-backref uniqueness.
- Generate quoted SQL identifiers, checks, indexes, FK declarations, and triggers.
- Include FK enforcement setup before transactions.
- Emit no application-side fallback for unsupported constraints.
- Report clear errors for unsupported SQLite requirements/features.

### Key compile errors

| Situation | Result |
| --- | --- |
| Unknown type/table/field | Error after whole-file resolution |
| Circular reusable types | Error |
| Duplicate SQL names after conversion/`#name` | Error |
| Nullable primary-key component | Error |
| `#allow reuse` on a non-key field, non-integer key, composite key, or PK+FK | Error |
| Default on auto-generated integer PK | Error |
| Both explicit default and `#use default` | Error |
| `#use default` without an available type default | Error |
| Undeclared enum default | Error |
| `#of` expands a named enum at field scope | Error |
| `setNull` on non-null FK | Error |
| FK target lacks a declared single-column PK | Error in v1 |
| Singular backref through a non-unique FK | Error |
| Non-null singular backref | Error in v1 |
| Nullable relationship collection | Error |
| Column-only configuration on `~` relation | Error |
| Ambiguous connection destination without `<<` | Error |
| Wrong-type source/destination endpoint | Error |
| `?` at table scope or `??` at field/type scope | Error |
| `_` at table scope | Error |
| Unsupported generated constraint/runtime UDF dependency | Error |
| Structured JSON default or stored array type | Unsupported in v1 |
| `as` naming | Unsupported |
| Mixed `=`/braced body or truly empty `=` body | Parse error |
| Direct `=` body items not exactly two spaces beyond the declaration, or mismatched siblings | Parse error |
| `=` body on index or constraint options | Parse error; braces required |
| Semicolon separators or leading indentation tabs outside literals | Parse error |
| Unattached docs or docs targeting directives/constraints | Parse error |
| Multiline strings/backticks | Unsupported in the initial parser |

Raw SQL is an intentional escape hatch. Static validation may not detect every
SQLite error; SQLite remains the authority on its syntax and enforcement rules.
Raw SQL and exact names should be treated as trusted schema-source input, not
untrusted application data.

**Open output details:** CLI format, destination file handling, generated-object
ordering, validation against an actual SQLite connection, and whether compiler
errors guarantee no partial output still need design. Prefer deterministic output
and fail-before-write behavior.

### Current supported-subset resolver

`src/resolver.zig` resolves manually constructed `parsed.Schema` values; no parser
is implemented. It still uses the historical `text` spelling, not the settled
`str` built-in, and must be updated; this is not a language alias. It supports
tables, stored fields, `int`/`real`/`text`/`blob`,
nullability, defaults, primary keys, `#name`, and field-level `#allow reuse`.
Unknown type names are errors; reusable type declarations are not modeled yet.
Literal integer defaults also fit `real`; other literal kinds must match their
storage type. Raw SQL defaults are trusted, not SQL-syntax-validated.

This is a historical description of the current resolver, not an implementation
of the newly settled parser syntax. Ordinary strings use quote doubling with
literal backslashes. Single-line hash-delimited raw strings preserve content
literally. Multiline strings are explicitly rejected. Backtick arguments currently
must have exactly one opening and closing delimiter; embedded backticks are
rejected. The parser plan requires updates to support hash-delimited backticks
and the other settled lexical and body rules in this document.

The API is `resolve(allocator, parsed_schema) -> Allocator.Error!Result`.
`Result.diagnostic` contains the first semantic error category, source span, and
static message. `Result.schema` contains an owned schema; call its `deinit()` once
when done. All arrays and strings are owned, so parsed input need not outlive the
result. Failure releases all partial allocations. Out-of-memory is separate from
semantic diagnostics. Resolution never emits partial SQL.

## 21. Consolidated example

```text
-- One source file. Order of declarations does not matter.

=> PublicationStatus enum(draft) =
  #of draft, published, archived
  #of `in review`

=> Rating int =
  ? _ >= 1 && _ <= 5

--- An author and their public identity.
Author {
  !id int
  name str =
    ? ::notEmpty

  email str? =
    ? unique

  *profile Profile? =
    ? unique

  ~books Book[] @Authorship.writerId
  ~translations Book[] @Translation.translatorId
}

Profile {
  !id int
  displayName str
  birthDate date?
  ~author Author? @Author.profile
}

Publisher {
  !id int
  name str
  ~books Book[] @Book.publisher
}

--- A book, stored separately from authorship metadata.
Book {
  #name `books`

  !id int

  title str =
    ? ::notEmpty
    #index

  status PublicationStatus =
    #use default

  *publisher Publisher? =
    #onDelete setNull

  price real(0) =
    ? _ >= 0

  publishedOn date?
  deletedAt datetime?
  createdAt datetime(::now)
  updatedAt datetime(::now) =
    #onUpdate ::now

  metadata json('{}')
  coverImage blob?

  ~authors Author[] @Authorship.publicationId
  ~translators Author[] @Translation.publicationId
  ~categories Category[] @.bookId
  ~reviews Review[] @Review.book

  #index publisher, publishedOn {
    #name `idx_books_publisher_date`
  }

  #index title {
    #name `idx_active_book_titles`
    #where deletedAt == null
  }
}

~Authorship(writer Author, publication Book) {
  ~~

  *!writerId Author =
    #name `writer_id`
    #onDelete cascade

  position int(0) =
    ? _ >= 0

  creditedAs str?
  addedAt datetime(::now)
}

~Translation(translator Author, publication Book) {
  ~~
  language str
}

Category {
  !id int
  name str
  *parent Category?
  ~children Category[] @Category.parent
  ~books Book[] @.categoryId
}

~(Book, Category) {
  ~~
  addedAt datetime(::now)
}

Reader {
  !id int

  username str =
    ? unique {
      #name `uq_reader_username`
    }

  email str?
  deletedAt datetime?

  ~settings ReaderSettings? @ReaderSettings.reader
  ~reviews Review[] @Review.reader
  ~following Reader[] @Following.followerId
  ~followers Reader[] @Following.followedId
  ~reviewers Reader[] @ReviewAssignment.authorId <<reviewerId
  ~approvers Reader[] @ReviewAssignment.authorId <<approverId

  #index email {
    #unique
    #where deletedAt == null
  }
}

--- Optional extension row sharing its reader's identity.
ReaderSettings {
  *!reader Reader =
    #onDelete cascade

  darkMode bool(false)
  preferences json('{}')
}

Review {
  !id int
  *reader Reader
  *book Book
  rating Rating
  body str
  createdAt datetime(::now)

  ?? unique(reader, book)
}

~Following(follower Reader, followed Reader) {
  ~~

  -- A self-connection does not implicitly forbid self-following.
  ?? followerId != followedId
}

Event {
  !id int
  title str

  eventTimezone str('UTC')

  startsAt datetime =
    #tz eventTimezone

  endsAt datetime =
    #tz eventTimezone

  ?? endsAt > startsAt
}

~ReviewAssignment(author Reader, reviewer Reader, approver Reader) {
  ~~
  *book Book
  assignedAt datetime(::now)
}

```

The example uses `::notEmpty` to demonstrate generated rules, subject to the
constraint catalog being defined. It does not rely on comprehensive email
validation, Unicode collation, timezone conversion, or automatic query loading.

## 22. Edge cases to test

### Parsing and scopes

- `=` bodies inside braced tables: direct items exactly two spaces beyond the
  declaration's actual indentation, including unusually indented declarations.
- Matching sibling indentation; rejected shallower or deeper direct items;
  deeper indentation only inside nested braced options with independent formatting.
- Blank lines and ordinary comments at varying indentation neither establish nor
  end `=` scope; dedented declarations and enclosing closing braces end it.
- Correctly indented comment-only `-- TODO` bodies versus truly empty `=` bodies.
- Rejected mixed `=`/braced bodies and `=` bodies on index/constraint options.
- Table opening braces on the header line, closing braces on their own line, and
  empty `{}`; rejected semicolons and leading indentation tabs.
- Parenthesized multiline expressions versus rejected bare continuations.
- Standalone consecutive docs, newline joining, optional-space stripping,
  ordinary-comment preservation, blank-line breaks, invalid targets, and orphans.
- ASCII identifiers, reserved `_`/`true`/`false`/`null`, and contextual keywords.
- Decimal negatives and leading zeros; rejected `.5`, `1.`, exponents, plus,
  hexadecimal numbers, and digit separators.
- A nullable type `str?` followed by a body containing `?` checks.
- `??` recognized as a table marker, not two nullable/check tokens.
- `<`, `<=`, and `<<` tokenization in their respective contexts.
- Comments immediately after enum values and normal declarations.
- Raw strings containing quotes, backslashes, comment prefixes, and delimiters.
- Multi-hash raw strings and mismatched hash counts.
- Hash-delimited backticks with embedded backticks and exact-count closing runs
  in SQL expression, SQL name, and enum text contexts.
- Rejected multiline strings/backticks in the initial parser.
- Deferred multiline feature tests: delimiter-only lines, dedent preserving
  relative spaces and blank lines, and `|`/`>` stripping only the first marker.

### Names and references

- Forward references to tables and types.
- Name collisions after camelCase conversion and exact `#name` overrides.
- SQL reserved words and embedded identifier quote characters.
- ASCII case-insensitive identifier collisions despite exact `#name` spelling.
- Raw SQL that references an old name after a field override: no rewriting.
- Acronym normalization: `HTTPServer` → `http_server`, `URLValue` → `url_value`.

### Enforcement

- Integer IDs with and without `#allow reuse` after deleting the highest row.
- Explicit inserts versus generated `AUTOINCREMENT` IDs.
- Explicit null generating a rowid-backed integer PK, but failing for a shared
  PK+FK in a `WITHOUT ROWID` table.
- Shared PK+FK missing its value, duplicate parent identity, missing parent.
- All composite-key components required; no automatic component generation.
- FK checks with `PRAGMA foreign_keys` off on another connection.
- Delete actions, including `setNull` nullability errors.
- Unique nullable fields with repeated nulls and with `nulls: equal`.
- Boolean values outside `0`/`1`.
- Invalid JSON literals and runtime JSON values.
- Nullable JSON accepting SQL null and JSON text `'null'` as distinct values.
- Invalid dates, leap days, timestamp precision, and UTC-only storage.
- Null-valued checks, negation, and rewritten null comparisons.
- Partial uniqueness and FK-index coverage without redundant indexes.

### Relationships and expansion

- Singular source FK unique versus non-unique.
- Orphan target rows allowed despite required forward FKs.
- Role-named self-connections and multi-endpoint destination ambiguity.
- `~~` enrichment by DSL field name without duplicate generated columns.
- Overrides that attempt to change generated key identity or nullability.
- Unnamed connection identity independent of endpoint order.
- Implicit references reusing an explicit unnamed connection without duplication.
- Multiple named connections between the same types.
- Explicit and generated timezone fields linked by name, including conflicts.

### Defaults and triggers

- Enum defaults absent from `#of` values.
- Inherited constraints with opt-in defaults.
- Conflicting/missing `#use default` and type-composition cycles.
- Explicit null versus omitted columns.
- Timestamp refresh on unchanged value versus preserving a changed value.
- Same-millisecond updates and recursive triggers enabled.
- Update timestamps on composite-key and keyless tables.

## 23. Remaining decisions before implementation

These are not new agreed requirements; they are gaps worth resolving explicitly.

1. Deferred multiline-string edge cases: blank markers, dedent tabs, and line
   endings. Single-line strings, quote doubling, literal backslashes, and
   hash-delimited backticks are settled.
2. Generated key/index/trigger naming. Ordinary camelCase/acronym conversion is
   settled in section 5.
3. Canonical generated key ordering for order-independent unnamed connections.
4. Full validator catalog for `::`, especially email and nonempty-string semantics.
5. Exact date/datetime format, precision, calendar validity checks, and accepted range.
6. Nullable/constrained explicit timezone-field compatibility.
7. Enum duplicate/empty-value rules and enum-literal syntax inside DSL expressions.
8. Composite uniqueness with nulls-equal semantics and naming of expanded objects.
9. Trigger SQL, no-op-update behavior, recursion safety, and row targeting.
10. Constraint restrictions in reusable types: value checks versus structural rules
    such as uniqueness or index directives.
11. Whether aliases of `int` receive exactly the same automatic-PK behavior.
12. Defaults on PK+FK fields: the no-generation rule is settled, but explicit
    default policy still needs clarification.
13. Connection-header role rules: mixed named/unnamed endpoints, duplicate role
    names, and general headers with non-`id` target keys.
14. How to name a primary-key constraint without introducing a conflicting scope.
15. Generated SQL ordering, validation strategy, and compiler output/error contract.

## 24. Deferred beyond v1

- Migrations, including renames and SQLite table rebuilds.
- Multi-file schemas, imports, and namespaces.
- Older SQLite compatibility modes.
- Composite foreign keys and their explicit local/target mapping syntax.
- Structured JSON literal parsing and its duplicate-key checks.
- Stored scalar arrays such as `str[]`.
- Query generation, eager loading, ORM/runtime helpers, or collection behavior.
- Application-side constraint fallback or custom runtime SQLite UDF requirements.
- `as` naming syntax and non-braced index/constraint option bodies.
- Automatic enforcement that every target has a reverse one-to-one row.

Role-named, self, and multi-endpoint connections are **not** deferred beyond v1;
they are planned for its later implementation stages.
