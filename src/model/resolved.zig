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

/// A stored column. Semantic resolution chooses its SQLite storage type.
pub const Column = struct {
    dsl_name: []const u8,
    sql_name: []const u8,
    type: StorageType,
    nullable: bool = false,
    primary_key: bool = false,
};

/// Virtual relationship metadata; never a stored column.
pub const Relationship = struct {};
