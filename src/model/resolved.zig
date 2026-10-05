//! Resolved schema model: the boundary between semantic resolution and SQL generation.

pub const Schema = struct {
    tables: []const Table = &.{},
    relationships: []const Relationship = &.{},
};

/// Stored tables, including expanded connection tables.
pub const Table = struct {
    dsl_name: []const u8,
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

/// A stored column. Semantic resolution chooses its SQLite storage type.
pub const Column = struct {
    dsl_name: []const u8,
    sql_name: []const u8,
    type: StorageType,
    nullable: bool = false,
    primary_key: PrimaryKey = .none,
};

/// Virtual relationship metadata; never a stored column.
pub const Relationship = struct {};
