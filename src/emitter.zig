//! SQLite SQL generation from the resolved schema.
const std = @import("std");
const resolved = @import("model/resolved.zig");

pub const Error = std.Io.Writer.Error || error{NullablePrimaryKey};

/// Emit tables and columns in schema order. Zero-column tables remain skeletons,
/// not executable SQLite SQL. Relationships are virtual and produce no SQL.
/// Nullable primary keys are rejected before writing. Writer failures may leave
/// partial output. The caller owns and flushes the writer.
pub fn emit(schema: resolved.Schema, writer: *std.Io.Writer) Error!void {
    for (schema.tables) |table| {
        for (table.columns) |column| {
            if (column.primary_key and column.nullable) return error.NullablePrimaryKey;
        }
    }

    try writer.writeAll("PRAGMA foreign_keys = ON;\n");
    for (schema.tables) |table| {
        var key_count: usize = 0;
        for (table.columns) |column| {
            if (column.primary_key) key_count += 1;
        }

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
            if (column.primary_key and key_count == 1 and column.type == .integer) {
                try writer.writeAll(" PRIMARY KEY AUTOINCREMENT");
            } else {
                if (!column.nullable) try writer.writeAll(" NOT NULL");
                if (column.primary_key and key_count == 1) try writer.writeAll(" PRIMARY KEY");
            }
            if (index + 1 < table.columns.len or key_count > 1) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        if (key_count > 1) {
            try writer.writeAll("  PRIMARY KEY (");
            var first = true;
            for (table.columns) |column| {
                if (!column.primary_key) continue;
                if (!first) try writer.writeAll(", ");
                try writeIdentifier(writer, column.sql_name);
                first = false;
            }
            try writer.writeAll(")\n");
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

test "single integer primary key generates IDs" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{.{
        .dsl_name = "Book",
        .sql_name = "book",
        .columns = &.{
            .{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = true },
            .{ .dsl_name = "title", .sql_name = "title", .type = .text },
        },
    }} }, &output.writer);
    try std.testing.expectEqualStrings(
        "PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"book\" (\n" ++
            "  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT,\n" ++
            "  \"title\" TEXT NOT NULL\n) STRICT;\n",
        output.written(),
    );
}

test "non-integer primary keys are required and do not generate IDs" {
    for ([_]resolved.StorageType{ .text, .real, .blob }) |storage_type| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try emit(.{ .tables = &.{.{
            .dsl_name = "Entry",
            .sql_name = "entry",
            .columns = &.{.{ .dsl_name = "key", .sql_name = "key", .type = storage_type, .primary_key = true }},
        }} }, &output.writer);
        const sql_type = switch (storage_type) {
            .text => "TEXT",
            .real => "REAL",
            .blob => "BLOB",
            .integer => unreachable,
        };
        const expected = try std.fmt.allocPrint(std.testing.allocator, "PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"entry\" (\n  \"key\" {s} NOT NULL PRIMARY KEY\n) STRICT;\n", .{sql_type});
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, output.written());
    }
}

test "composite primary key preserves column order and quotes SQL names" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{.{
        .dsl_name = "Entry",
        .sql_name = "entry",
        .columns = &.{
            .{ .dsl_name = "tenantId", .sql_name = "tenant\"id", .type = .integer, .primary_key = true },
            .{ .dsl_name = "value", .sql_name = "value", .type = .text },
            .{ .dsl_name = "key", .sql_name = "select", .type = .text, .primary_key = true },
        },
    }} }, &output.writer);
    try std.testing.expectEqualStrings(
        "PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"entry\" (\n" ++
            "  \"tenant\"\"id\" INTEGER NOT NULL,\n" ++
            "  \"value\" TEXT NOT NULL,\n" ++
            "  \"select\" TEXT NOT NULL,\n" ++
            "  PRIMARY KEY (\"tenant\"\"id\", \"select\")\n) STRICT;\n",
        output.written(),
    );
}

test "nullable primary keys fail before writing any table" {
    for ([_]bool{ false, true }) |composite| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectError(error.NullablePrimaryKey, emit(.{ .tables = &.{
            .{ .dsl_name = "Valid", .sql_name = "valid" },
            .{
                .dsl_name = "Invalid",
                .sql_name = "invalid",
                .columns = &.{
                    .{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = true, .nullable = true },
                    .{ .dsl_name = "other", .sql_name = "other", .type = .text, .primary_key = composite },
                },
            },
        } }, &output.writer));
        try std.testing.expectEqualStrings("", output.written());
    }
}
