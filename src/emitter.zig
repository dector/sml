//! SQLite SQL generation from the resolved schema.
const std = @import("std");
const resolved = @import("model/resolved.zig");

pub const Error = std.Io.Writer.Error;

/// Emit tables and columns in schema order. Zero-column tables remain skeletons,
/// not executable SQLite SQL. Relationships are virtual and produce no SQL.
/// Writer failures may leave partial output. The caller owns and flushes the writer.
pub fn emit(schema: resolved.Schema, writer: *std.Io.Writer) Error!void {
    try writer.writeAll("PRAGMA foreign_keys = ON;\n");
    for (schema.tables) |table| {
        try writer.writeAll("\nCREATE TABLE ");
        try writeIdentifier(writer, table.sql_name);
        try writer.writeAll(" (\n");
        for (table.columns, 0..) |column, index| {
            try writer.writeAll("  ");
            try writeIdentifier(writer, column.sql_name);
            try writer.writeByte(' ');
            try writer.writeAll(switch (column.type) {
                .integer => "INTEGER",
                .real => "REAL",
                .text => "TEXT",
                .blob => "BLOB",
            });
            if (!column.nullable) try writer.writeAll(" NOT NULL");
            if (index + 1 < table.columns.len) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        try writer.writeAll(") STRICT;\n");
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

test "columns emit every storage type with nullability and commas" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{.{
        .dsl_name = "Book",
        .sql_name = "book",
        .columns = &.{
            .{ .dsl_name = "pageCount", .sql_name = "page_count", .type = .integer },
            .{ .dsl_name = "price", .sql_name = "price", .type = .real, .nullable = true },
            .{ .dsl_name = "title", .sql_name = "title", .type = .text },
            .{ .dsl_name = "cover", .sql_name = "cover", .type = .blob, .nullable = true },
        },
    }} }, &output.writer);
    try std.testing.expectEqualStrings(
        "PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"book\" (\n" ++
            "  \"page_count\" INTEGER NOT NULL,\n" ++
            "  \"price\" REAL,\n" ++
            "  \"title\" TEXT NOT NULL,\n" ++
            "  \"cover\" BLOB\n) STRICT;\n",
        output.written(),
    );
}

test "single column uses its quoted SQL name without a trailing comma" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{.{
        .dsl_name = "Book",
        .sql_name = "book",
        .columns = &.{.{ .dsl_name = "title", .sql_name = "Display\"Name", .type = .text }},
    }} }, &output.writer);
    try std.testing.expectEqualStrings(
        "PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"book\" (\n  \"Display\"\"Name\" TEXT NOT NULL\n) STRICT;\n",
        output.written(),
    );
}
