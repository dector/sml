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
    documentation: ?Documentation = null,
    sql_name: []const u8,
    columns: []const Column = &.{},
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
    default: ?Default = null,
};

/// Virtual relationship metadata; never a stored column.
pub const Relationship = struct {};
