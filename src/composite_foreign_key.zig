//! Validation of table-level foreign keys to connection composite primary keys.
const std = @import("std");
const resolved = @import("model/resolved.zig");

pub const Error = error{ InvalidForeignKey, InvalidIdentifier, InvalidIdReuse };

/// Validate all groups and their component ownership before scalar FK validation
/// may skip composite-marked columns. No allocation or output is performed.
pub fn validate(schema: resolved.Schema, table: resolved.Table) Error!void {
    if (table.composite_foreign_keys.len != 0 and table.connection == null) return error.InvalidForeignKey;
    for (table.composite_foreign_keys, 0..) |group, group_index| {
        if (group.columns.len < 2) return error.InvalidForeignKey;
        for (group.columns, 0..) |ci, i| {
            if (ci >= table.columns.len or std.mem.indexOfScalar(usize, group.columns[0..i], ci) != null)
                return error.InvalidForeignKey;
            for (table.composite_foreign_keys[0..group_index]) |prior| {
                if (std.mem.indexOfScalar(usize, prior.columns, ci) != null) return error.InvalidForeignKey;
            }
            const column = table.columns[ci];
            const fk = column.foreign_key orelse return error.InvalidForeignKey;
            if (!fk.composite) return error.InvalidForeignKey;
            if (column.primary_key == .allow_reuse) return error.InvalidIdReuse;
            if (fk.delete_action == .set_null and !column.nullable) return error.InvalidForeignKey;
            for ([_][]const u8{ fk.target_table_sql_name, fk.target_column_sql_name }) |name| {
                if (!validName(name)) return error.InvalidIdentifier;
            }
        }
        const first = table.columns[group.columns[0]].foreign_key.?;
        const target = for (schema.tables) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.sql_name, first.target_table_sql_name)) break candidate;
        } else return error.InvalidForeignKey;
        if (target.connection == null) return error.InvalidForeignKey;
        var key_index: usize = 0;
        for (target.columns) |key| {
            if (key.primary_key == .none) continue;
            if (key_index >= group.columns.len) return error.InvalidForeignKey;
            const column = table.columns[group.columns[key_index]];
            const fk = column.foreign_key.?;
            if (!validName(key.sql_name)) return error.InvalidIdentifier;
            if (!std.ascii.eqlIgnoreCase(fk.target_table_sql_name, target.sql_name) or
                !std.ascii.eqlIgnoreCase(fk.target_column_sql_name, key.sql_name) or
                fk.delete_action != first.delete_action or key.nullable or
                key.type == .boolean or key.type != column.type or
                key.enum_values.len != column.enum_values.len)
                return error.InvalidForeignKey;
            for (key.enum_values) |value| {
                if (!@import("enumeration.zig").contains(column.enum_values, value)) return error.InvalidForeignKey;
            }
            key_index += 1;
        }
        if (key_index != group.columns.len) return error.InvalidForeignKey;
    }
    for (table.columns, 0..) |column, ci| {
        const fk = column.foreign_key orelse continue;
        if (!fk.composite) continue;
        const found = for (table.composite_foreign_keys) |group| {
            if (std.mem.indexOfScalar(usize, group.columns, ci) != null) break true;
        } else false;
        if (!found) return error.InvalidForeignKey;
    }
}

fn validName(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfScalar(u8, name, 0) == null;
}

const parent_columns = [_]resolved.Column{
    .{ .dsl_name = "a", .sql_name = "a", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "A", .target_column_sql_name = "id" } },
    .{ .dsl_name = "b", .sql_name = "b", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "B", .target_column_sql_name = "id" } },
};
const child_columns = [_]resolved.Column{
    .{ .dsl_name = "ab_a", .sql_name = "ab_a", .type = .integer, .primary_key = .standard, .foreign_key = .{ .composite = true, .target_table_sql_name = "AB", .target_column_sql_name = "a", .delete_action = .cascade } },
    .{ .dsl_name = "ab_b", .sql_name = "ab_b", .type = .integer, .primary_key = .standard, .foreign_key = .{ .composite = true, .target_table_sql_name = "AB", .target_column_sql_name = "b", .delete_action = .cascade } },
    .{ .dsl_name = "a", .sql_name = "a", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "A", .target_column_sql_name = "id" } },
};
const fixture_tables = [_]resolved.Table{
    .{ .dsl_name = "A", .sql_name = "A", .columns = &.{.{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard }} },
    .{ .dsl_name = "B", .sql_name = "B", .columns = &.{.{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard }} },
    .{ .dsl_name = "AB", .sql_name = "AB", .columns = &parent_columns, .connection = .{ .endpoints = &.{ .{ .table_index = 0, .column_index = 0 }, .{ .table_index = 1, .column_index = 1 } } } },
    .{ .dsl_name = "ABA", .sql_name = "ABA", .columns = &child_columns, .connection = .{ .endpoints = &.{ .{ .table_index = 2, .column_indices = &.{ 0, 1 } }, .{ .table_index = 0, .column_index = 2 } } }, .composite_foreign_keys = &.{.{ .columns = &.{ 0, 1 } }}, .unique_constraints = &.{.{ .columns = &.{ 0, 2 } }} },
};

test "composite FK groups require complete ordered unique ownership" {
    const schema: resolved.Schema = .{ .tables = &fixture_tables };
    var table = fixture_tables[3];
    try validate(schema, table);
    for ([_][]const usize{ &.{}, &.{0}, &.{ 0, 0 }, &.{ 0, 9 }, &.{ 1, 0 }, &.{ 0, 2 } }) |indices| {
        table.composite_foreign_keys = &.{.{ .columns = indices }};
        try std.testing.expectError(error.InvalidForeignKey, validate(schema, table));
    }
    table.composite_foreign_keys = &.{};
    try std.testing.expectError(error.InvalidForeignKey, validate(schema, table));
    table.composite_foreign_keys = &.{ .{ .columns = &.{ 0, 1 } }, .{ .columns = &.{ 0, 1 } } };
    try std.testing.expectError(error.InvalidForeignKey, validate(schema, table));
    table = fixture_tables[3];
    table.connection = null;
    try std.testing.expectError(error.InvalidForeignKey, validate(schema, table));
}

test "composite FK components check action target names types and parent nullability" {
    for (0..8) |mutation| {
        var tables = fixture_tables;
        var columns = child_columns;
        var parent = parent_columns;
        tables[3].columns = &columns;
        tables[2].columns = &parent;
        switch (mutation) {
            0 => columns[1].foreign_key.?.delete_action = .restrict,
            1 => columns[1].foreign_key.?.target_table_sql_name = "B",
            2 => columns[1].foreign_key.?.target_column_sql_name = "a",
            3 => columns[1].type = .text,
            4 => parent[1].nullable = true,
            5 => tables[2].connection = null,
            6 => columns[1].foreign_key.?.composite = false,
            7 => {
                columns[0].foreign_key.?.delete_action = .set_null;
                columns[1].foreign_key.?.delete_action = .set_null;
            },
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidForeignKey, validate(.{ .tables = &tables }, tables[3]));
    }
    var columns = child_columns;
    columns[1].foreign_key.?.target_column_sql_name = "bad\x00name";
    var table = fixture_tables[3];
    table.columns = &columns;
    try std.testing.expectError(error.InvalidIdentifier, validate(.{ .tables = &fixture_tables }, table));
}

test "composite FK enums compare exact value sets and names ignore ASCII case" {
    var tables = fixture_tables;
    var columns = child_columns;
    var parent = parent_columns;
    tables[3].columns = &columns;
    tables[2].columns = &parent;
    parent[1].type = .enumeration;
    parent[1].enum_values = &.{ "one", "two" };
    columns[1].type = .enumeration;
    columns[1].enum_values = &.{ "two", "one" };
    columns[1].foreign_key.?.target_table_sql_name = "ab";
    columns[1].foreign_key.?.target_column_sql_name = "B";
    try validate(.{ .tables = &tables }, tables[3]);
    columns[1].enum_values = &.{ "two", "ONE" };
    try std.testing.expectError(error.InvalidForeignKey, validate(.{ .tables = &tables }, tables[3]));
    columns[1].enum_values = &.{"one"};
    try std.testing.expectError(error.InvalidForeignKey, validate(.{ .tables = &tables }, tables[3]));
}

test "composite FK emission follows UNIQUE and suppresses inline references" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try @import("emitter.zig").emit(.{ .tables = &fixture_tables }, &output.writer);
    const sql = output.written();
    try std.testing.expect(std.mem.indexOf(u8, sql, "  \"ab_a\" INTEGER NOT NULL,\n  \"ab_b\" INTEGER NOT NULL,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "  UNIQUE (\"ab_a\", \"a\"),\n  FOREIGN KEY (\"ab_a\", \"ab_b\") REFERENCES \"AB\" (\"a\", \"b\") ON DELETE CASCADE\n) STRICT;") != null);
}

test "invalid composite groups and scalar relationships write nothing" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var tables = fixture_tables;
    tables[3].composite_foreign_keys = &.{};
    try std.testing.expectError(error.InvalidForeignKey, @import("emitter.zig").emit(.{ .tables = &tables }, &output.writer));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try std.testing.expectError(error.InvalidRelationship, @import("emitter.zig").emit(.{ .tables = &fixture_tables, .relationships = &.{.{ .dsl_name = "items", .owner_table_index = 2, .target_table_index = 0, .source_table_index = 3, .backing_column_index = 0, .destination_column_index = 2, .cardinality = .many }} }, &output.writer));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
