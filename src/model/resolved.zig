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

/// A stored column.
pub const Column = struct {
    dsl_name: []const u8,
    sql_name: []const u8,
};

/// Virtual relationship metadata; never a stored column.
pub const Relationship = struct {};

