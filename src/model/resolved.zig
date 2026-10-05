//! Resolved schema model: the boundary between semantic resolution and SQL generation.

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

/// SQLite storage types supported by the resolved model.
pub const StorageType = enum {
    integer,
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
pub const Default = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
    null_value,
    raw_sql: []const u8,
};

/// A stored column. Semantic resolution chooses its SQLite storage type.
pub const Column = struct {
    dsl_name: []const u8,
    documentation: ?Documentation = null,
    sql_name: []const u8,
    type: StorageType,
    nullable: bool = false,
    primary_key: PrimaryKey = .none,
    default: ?Default = null,
};

/// Virtual relationship metadata; never a stored column.
pub const Relationship = struct {};
