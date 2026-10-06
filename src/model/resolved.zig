//! Resolved schema model: the boundary between semantic resolution and SQL generation.

pub const Expression = @import("resolved_expression.zig").Expression;

pub const Documentation = struct {
    text: []const u8,
    span: @import("parsed.zig").Span,
};

pub const Schema = struct {
    tables: []const Table = &.{},
    relationships: []const Relationship = &.{},
};

/// Stored tables, including expanded connection tables.
pub const Table = struct {
    dsl_name: []const u8,
    connection: ?Connection = null,
    documentation: ?Documentation = null,
    sql_name: []const u8,
    columns: []const Column = &.{},
    unique_constraints: []const UniqueConstraint = &.{},
    indexes: []const Index = &.{},
    /// Explicit table checks in directive source order.
    checks: []const Expression = &.{},
};

/// Named connection metadata; endpoint binding is deferred to a later slice.
pub const Connection = struct {
    endpoints: []const Endpoint,
};

pub const Endpoint = struct {
    table_index: usize,
    role: ?[]const u8 = null,
    /// Local explicit FK column, when bound.
    column_index: ?usize = null,
};

/// Logical column types. Boolean uses INTEGER; datetime and enumeration use TEXT.
pub const StorageType = enum {
    integer,
    boolean,
    datetime,
    enumeration,
    real,
    text,
    blob,
};

/// Primary-key membership and ID generation policy.
pub const PrimaryKey = enum {
    none,
    /// Single integer keys generate IDs only when foreign_key is null.
    standard,
    /// `#allow reuse`: omit AUTOINCREMENT on a single integer primary key.
    allow_reuse,
};

/// A resolved literal or trusted SQLite default expression.
/// No default is represented by a null optional, not `null_value`.
/// Enum literals use `text`; direct `raw_sql` remains a trusted escape hatch.
pub const Default = union(enum) {
    integer: i64,
    boolean: bool,
    datetime: []const u8,
    now,
    real: f64,
    text: []const u8,
    blob: []const u8,
    null_value,
    raw_sql: []const u8,
};

/// Indexes own ordered column indices and their exact SQL name.
pub const Index = struct {
    columns: []const usize,
    sql_name: []const u8,
    unique: bool = false,
    predicate: ?Expression = null,
};

pub const UniqueConstraint = struct {
    /// Table constraints own ordered column indices; empty for column constraints.
    columns: []const usize = &.{},
    name: ?[]const u8 = null,
    nulls: enum { distinct, equal } = .distinct,
};

/// FK deletion policy. No update actions are modeled.
pub const DeleteAction = enum { restrict, cascade, set_null };

/// Resolved single-column FK metadata; SQL names are owned with the schema.
/// The local Column carries the inherited logical type and enum allowed values.
/// Public schemas must match the target's single PK by ASCII-case-insensitive
/// SQL name, logical type, and exact enum value set. Emission preflights this.
pub const ForeignKey = struct {
    target_table_sql_name: []const u8,
    target_column_sql_name: []const u8,
    delete_action: DeleteAction = .restrict,
};

/// A stored column. Semantic resolution chooses its logical/storage type.
pub const Column = struct {
    dsl_name: []const u8,
    documentation: ?Documentation = null,
    sql_name: []const u8,
    type: StorageType,
    /// Nonempty, exact-byte unique decoded values for enumeration only.
    enum_values: []const []const u8 = &.{},
    nullable: bool = false,
    primary_key: PrimaryKey = .none,
    foreign_key: ?ForeignKey = null,
    default: ?Default = null,
    /// Explicit field checks in source order; builtin checks are emitted separately.
    checks: []const Expression = &.{},
    unique_constraints: []const UniqueConstraint = &.{},
};

/// Virtual relationship metadata; never a stored column.
pub const RelationshipCardinality = enum { many, optional_one };

pub const Relationship = struct {
    dsl_name: []const u8,
    /// Indices into Schema.tables; the backing column belongs to source_table_index.
    owner_table_index: usize,
    target_table_index: usize,
    source_table_index: usize,
    backing_column_index: usize,
    cardinality: RelationshipCardinality,
    documentation: ?Documentation = null,
    span: ?@import("parsed.zig").Span = null,
};
