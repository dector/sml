//! SQLite SQL generation from the resolved schema.
const std = @import("std");
const resolved = @import("model/resolved.zig");

pub const Error = std.Io.Writer.Error || error{UnsupportedColumns};

/// Emit table skeletons in schema order. Zero-column tables are not executable
/// SQLite SQL yet. Relationships are virtual and produce no SQL.
/// Unsupported columns are checked before writing; writer failures may leave
/// partial output. The caller owns and flushes the writer.
pub fn emit(schema: resolved.Schema, writer: *std.Io.Writer) Error!void {
    for (schema.tables) |table| {
        if (table.columns.len != 0) return error.UnsupportedColumns;
    }

    try writer.writeAll("PRAGMA foreign_keys = ON;\n");
    for (schema.tables) |table| {
        try writer.writeAll("\nCREATE TABLE ");
        try writeIdentifier(writer, table.sql_name);
        try writer.writeAll(" (\n) STRICT;\n");
    }
}

fn writeIdentifier(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (name) |byte| {
        try writer.writeByte(byte);
        if (byte == '"') try writer.writeByte('"');
    }
    try writer.writeByte('"');
}

test "empty schema emits foreign key setup only" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{}, &output.writer);
    try std.testing.expectEqualStrings("PRAGMA foreign_keys = ON;\n", output.written());
}

test "empty tables use SQL names and preserve schema order" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{
        .{ .dsl_name = "Book", .sql_name = "books" },
        .{ .dsl_name = "Author", .sql_name = "author" },
    } }, &output.writer);
    try std.testing.expectEqualStrings(
        "PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"books\" (\n) STRICT;\n\nCREATE TABLE \"author\" (\n) STRICT;\n",
        output.written(),
    );
}

test "SQL identifiers preserve spelling and escape quotes" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{
        .{ .dsl_name = "Selection", .sql_name = "select" },
        .{ .dsl_name = "Writer", .sql_name = "Writer\"ID" },
    } }, &output.writer);
    try std.testing.expectEqualStrings(
        "PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"select\" (\n) STRICT;\n\nCREATE TABLE \"Writer\"\"ID\" (\n) STRICT;\n",
        output.written(),
    );
}

test "virtual relationships produce no SQL" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .relationships = &.{.{}} }, &output.writer);
    try std.testing.expectEqualStrings("PRAGMA foreign_keys = ON;\n", output.written());
}

test "unsupported columns fail before any output" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(error.UnsupportedColumns, emit(.{ .tables = &.{
        .{ .dsl_name = "Author", .sql_name = "author" },
        .{
            .dsl_name = "Book",
            .sql_name = "book",
            .columns = &.{.{ .dsl_name = "title", .sql_name = "title" }},
        },
    } }, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
}
