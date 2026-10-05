//! SQLite SQL generation from the resolved schema.
const std = @import("std");
const resolved = @import("model/resolved.zig");

pub const Error = std.Io.Writer.Error || error{ InvalidIdentifier, NullablePrimaryKey, InvalidPrimaryKey, InvalidIdReuse, InvalidDefault, InvalidEnum, DefaultOnAutoPrimaryKey };

/// Emit tables and columns in schema order. Zero-column tables remain skeletons,
/// not executable SQLite SQL. Relationships are virtual and produce no SQL.
/// NUL-containing SQL names, invalid primary keys, ID reuse options, and literal
/// defaults and enum metadata are rejected before writing. Raw SQL is trusted
/// and not syntax-validated, including direct resolved enum raw-SQL defaults.
/// Writer failures may leave partial output. The caller owns and flushes the writer.
pub fn emit(schema: resolved.Schema, writer: *std.Io.Writer) Error!void {
    for (schema.tables) |table| {
        if (std.mem.indexOfScalar(u8, table.sql_name, 0) != null) return error.InvalidIdentifier;
        const key_count = primaryKeyCount(table);
        for (table.columns) |column| {
            if (std.mem.indexOfScalar(u8, column.sql_name, 0) != null) return error.InvalidIdentifier;
            if (column.primary_key != .none and column.nullable) return error.NullablePrimaryKey;
            if (column.primary_key != .none and column.type == .boolean) return error.InvalidPrimaryKey;
            if (column.primary_key == .allow_reuse and
                (column.type != .integer or key_count != 1))
            {
                return error.InvalidIdReuse;
            }
            if (column.type == .enumeration) {
                if (!@import("enumeration.zig").valid(column.enum_values)) return error.InvalidEnum;
            } else if (column.enum_values.len != 0) return error.InvalidEnum;
            if (column.default) |value| {
                if (column.primary_key != .none and key_count == 1 and column.type == .integer)
                    return error.DefaultOnAutoPrimaryKey;
                try validateDefault(column, value);
            }
        }
    }

    try writer.writeAll("PRAGMA foreign_keys = ON;\n");
    for (schema.tables) |table| {
        const key_count = primaryKeyCount(table);

        try writer.writeByte('\n');
        if (table.documentation) |docs| try writeDocumentation(writer, docs.text, "");
        try writer.writeAll("CREATE TABLE ");
        try writeIdentifier(writer, table.sql_name);
        try writer.writeAll(" (\n");
        for (table.columns, 0..) |column, index| {
            if (column.documentation) |docs| try writeDocumentation(writer, docs.text, "  ");
            try writer.writeAll("  ");
            try writeIdentifier(writer, column.sql_name);
            try writer.writeByte(' ');
            try writer.writeAll(switch (column.type) {
                .integer, .boolean => "INTEGER",
                .real => "REAL",
                .text, .datetime, .enumeration => "TEXT",
                .blob => "BLOB",
            });
            if (column.primary_key != .none and key_count == 1 and column.type == .integer) {
                try writer.writeAll(" PRIMARY KEY");
                if (column.primary_key == .standard) try writer.writeAll(" AUTOINCREMENT");
            } else {
                if (!column.nullable) try writer.writeAll(" NOT NULL");
                if (column.primary_key != .none and key_count == 1) try writer.writeAll(" PRIMARY KEY");
            }
            if (column.default) |value| {
                try writer.writeAll(" DEFAULT ");
                try writeDefault(writer, value);
            }
            if (column.type == .enumeration) {
                try writer.writeAll(" CHECK (");
                try writeIdentifier(writer, column.sql_name);
                try writer.writeAll(" IN (");
                for (column.enum_values, 0..) |text, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writeText(writer, text);
                }
                try writer.writeAll("))");
            }
            if (column.type == .boolean) {
                // IN yields NULL for SQL NULL, allowing nullable Boolean fields.
                try writer.writeAll(" CHECK (");
                try writeIdentifier(writer, column.sql_name);
                try writer.writeAll(" IN (0, 1))");
            }
            if (column.type == .datetime) {
                var pieces = std.mem.splitScalar(u8, @import("datetime.zig").check, '@');
                try writer.writeAll(pieces.next().?);
                while (pieces.next()) |piece| {
                    try writeIdentifier(writer, column.sql_name);
                    try writer.writeAll(piece);
                }
            }
            if (index + 1 < table.columns.len or key_count > 1) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        if (key_count > 1) {
            try writer.writeAll("  PRIMARY KEY (");
            var first = true;
            for (table.columns) |column| {
                if (column.primary_key == .none) continue;
                if (!first) try writer.writeAll(", ");
                try writeIdentifier(writer, column.sql_name);
                first = false;
            }
            try writer.writeAll(")\n");
        }
        try writer.writeAll(") STRICT;\n");
    }
}

/// Prefix every physical line, including CR-separated lines, so docs cannot
/// inject SQL. NUL is rendered visibly rather than terminating SQLite source.
fn writeDocumentation(writer: *std.Io.Writer, text: []const u8, indent: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(indent);
    try writer.writeAll("-- ");
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\r', '\n' => {
                if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
                try writer.writeByte('\n');
                try writer.writeAll(indent);
                try writer.writeAll("-- ");
            },
            0 => try writer.writeAll("\\0"),
            else => try writer.writeByte(text[i]),
        }
    }
    try writer.writeByte('\n');
}

fn validateDefault(column: resolved.Column, value: resolved.Default) Error!void {
    const valid = switch (value) {
        .integer => column.type == .integer or column.type == .real,
        .boolean => column.type == .boolean,
        .real => |number| column.type == .real and std.math.isFinite(number),
        .text => |text| column.type == .text or (column.type == .enumeration and @import("enumeration.zig").contains(column.enum_values, text)),
        .datetime => |text| column.type == .datetime and @import("datetime.zig").valid(text),
        .now => column.type == .datetime,
        .blob => column.type == .blob,
        .null_value => column.nullable,
        .raw_sql => true,
    };
    if (!valid) return error.InvalidDefault;
}

fn writeDefault(writer: *std.Io.Writer, value: resolved.Default) std.Io.Writer.Error!void {
    switch (value) {
        .integer => |number| try writer.print("{d}", .{number}),
        .boolean => |value_bool| try writer.writeAll(if (value_bool) "1" else "0"),
        .real => |number| try writer.print("{d}", .{number}),
        .now => try writer.writeAll("(strftime('%Y-%m-%dT%H:%M:%SZ','now'))"),
        .text, .datetime => |text| try writeText(writer, text),
        .blob => |bytes| try writeBlob(writer, bytes),
        .null_value => try writer.writeAll("NULL"),
        .raw_sql => |sql| {
            try writer.writeByte('(');
            try writer.writeAll(sql);
            try writer.writeByte(')');
        },
    }
}

/// char(0) rather than CAST(UTF-8 blob AS TEXT): SQLite blob casts use the
/// database encoding and corrupt UTF-8 bytes in UTF-16 databases.
fn writeText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    const has_nul = std.mem.indexOfScalar(u8, text, 0) != null;
    if (has_nul) try writer.writeByte('(');
    var pieces = std.mem.splitScalar(u8, text, 0);
    var first = true;
    while (pieces.next()) |piece| {
        if (!first) try writer.writeAll(" || char(0) || ");
        first = false;
        try writer.writeByte('\'');
        for (piece) |byte| {
            try writer.writeByte(byte);
            if (byte == '\'') try writer.writeByte('\'');
        }
        try writer.writeByte('\'');
    }
    if (has_nul) try writer.writeByte(')');
}

fn writeBlob(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    try writer.writeAll("X'");
    for (bytes) |byte| {
        try writer.writeByte(hex[byte >> 4]);
        try writer.writeByte(hex[byte & 0x0f]);
    }
    try writer.writeByte('\'');
}

fn primaryKeyCount(table: resolved.Table) usize {
    var count: usize = 0;
    for (table.columns) |column| {
        if (column.primary_key != .none) count += 1;
    }
    return count;
}

fn writeIdentifier(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (name) |byte| {
        try writer.writeByte(byte);
        if (byte == '"') try writer.writeByte('"');
    }
    try writer.writeByte('"');
}

test "NUL in table or column SQL names fails before writing" {
    for ([_][]const u8{ "\x00name", "na\x00me", "name\x00" }) |invalid_name| {
        for ([_]bool{ false, true }) |invalid_table| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            try std.testing.expectError(error.InvalidIdentifier, emit(.{ .tables = &.{
                .{ .dsl_name = "Valid", .sql_name = "valid" },
                .{
                    .dsl_name = "Invalid",
                    .sql_name = if (invalid_table) invalid_name else "invalid",
                    .columns = &.{.{
                        .dsl_name = "value",
                        .sql_name = if (invalid_table) "value" else invalid_name,
                        .type = .text,
                    }},
                },
            } }, &output.writer));
            try std.testing.expectEqualStrings("", output.written());
        }
    }
}

test "literal and raw SQL defaults" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try emit(.{ .tables = &.{
        .{
            .dsl_name = "Settings",
            .sql_name = "settings",
            .columns = &.{
                .{ .dsl_name = "count", .sql_name = "count", .type = .integer, .default = .{ .integer = -7 } },
                .{ .dsl_name = "ratio", .sql_name = "ratio", .type = .real, .default = .{ .real = 1.25 } },
                .{ .dsl_name = "whole", .sql_name = "whole", .type = .real, .default = .{ .integer = 2 } },
                .{ .dsl_name = "label", .sql_name = "label", .type = .text, .default = .{ .text = "It's ready" } },
                .{ .dsl_name = "emptyText", .sql_name = "empty_text", .type = .text, .default = .{ .text = "" } },
                .{ .dsl_name = "payload", .sql_name = "payload", .type = .blob, .default = .{ .blob = "\x00\xff\x27" } },
                .{ .dsl_name = "emptyBlob", .sql_name = "empty_blob", .type = .blob, .default = .{ .blob = "" } },
                .{ .dsl_name = "optional", .sql_name = "optional", .type = .text, .nullable = true, .default = .null_value },
                .{ .dsl_name = "createdAt", .sql_name = "created_at", .type = .text, .default = .{ .raw_sql = "strftime('%Y', 'now')" } },
                .{ .dsl_name = "nulText", .sql_name = "nul_text", .type = .text, .default = .{ .text = "a\x00b" } },
                .{ .dsl_name = "noDefault", .sql_name = "no_default", .type = .integer },
            },
        },
        .{
            .dsl_name = "Code",
            .sql_name = "code",
            .columns = &.{.{ .dsl_name = "key", .sql_name = "key", .type = .text, .primary_key = .standard, .default = .{ .text = "initial" } }},
        },
        .{
            .dsl_name = "Pair",
            .sql_name = "pair",
            .columns = &.{
                .{ .dsl_name = "first", .sql_name = "first", .type = .integer, .primary_key = .standard, .default = .{ .integer = 1 } },
                .{ .dsl_name = "second", .sql_name = "second", .type = .integer, .primary_key = .standard, .default = .{ .integer = 2 } },
            },
        },
    } }, &output.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/emitter/defaults.expect.sql"), output.written());
}

test "incompatible and non-finite defaults fail before writing" {
    const cases = [_]struct { type: resolved.StorageType, value: resolved.Default }{
        .{ .type = .integer, .value = .{ .real = 1.5 } },
        .{ .type = .integer, .value = .{ .text = "1" } },
        .{ .type = .real, .value = .{ .blob = "1" } },
        .{ .type = .text, .value = .{ .integer = 1 } },
        .{ .type = .blob, .value = .{ .text = "data" } },
        .{ .type = .real, .value = .{ .real = std.math.inf(f64) } },
        .{ .type = .real, .value = .{ .real = -std.math.inf(f64) } },
        .{ .type = .real, .value = .{ .real = std.math.nan(f64) } },
    };
    for (cases) |case| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectError(error.InvalidDefault, emit(.{ .tables = &.{
            .{ .dsl_name = "Valid", .sql_name = "valid" },
            .{ .dsl_name = "Invalid", .sql_name = "invalid", .columns = &.{.{
                .dsl_name = "value",
                .sql_name = "value",
                .type = case.type,
                .default = case.value,
            }} },
        } }, &output.writer));
        try std.testing.expectEqualStrings("", output.written());
    }
}

test "null defaults require nullable columns" {
    for ([_]resolved.StorageType{ .integer, .real, .text, .blob }) |storage_type| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectError(error.InvalidDefault, emit(.{ .tables = &.{.{
            .dsl_name = "Invalid",
            .sql_name = "invalid",
            .columns = &.{.{
                .dsl_name = "value",
                .sql_name = "value",
                .type = storage_type,
                .default = .null_value,
            }},
        }} }, &output.writer));
        try std.testing.expectEqualStrings("", output.written());
    }
}

test "auto-generated integer primary keys reject every default" {
    for ([_]resolved.PrimaryKey{ .standard, .allow_reuse }) |primary_key| {
        for ([_]resolved.Default{ .{ .integer = 1 }, .{ .raw_sql = "1" }, .null_value }) |value| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            try std.testing.expectError(error.DefaultOnAutoPrimaryKey, emit(.{ .tables = &.{
                .{ .dsl_name = "Valid", .sql_name = "valid" },
                .{ .dsl_name = "Invalid", .sql_name = "invalid", .columns = &.{.{
                    .dsl_name = "id",
                    .sql_name = "id",
                    .type = .integer,
                    .primary_key = primary_key,
                    .default = value,
                }} },
            } }, &output.writer));
            try std.testing.expectEqualStrings("", output.written());
        }
    }
}

test "empty schema emits foreign key setup only" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{}, &output.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/emitter/empty_schema.expect.sql"), output.written());
}

test "empty tables use SQL names and preserve schema order" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{
        .{ .dsl_name = "Book", .sql_name = "books" },
        .{ .dsl_name = "Author", .sql_name = "author" },
    } }, &output.writer);
    try std.testing.expectEqualStrings(
        @embedFile("testdata/emitter/empty_tables.expect.sql"),
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
        @embedFile("testdata/emitter/quoted_tables.expect.sql"),
        output.written(),
    );
}

test "virtual relationships produce no SQL" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .relationships = &.{.{}} }, &output.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/emitter/empty_schema.expect.sql"), output.written());
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
        @embedFile("testdata/emitter/columns.expect.sql"),
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
        @embedFile("testdata/emitter/quoted_column.expect.sql"),
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
            .{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard },
            .{ .dsl_name = "title", .sql_name = "title", .type = .text },
        },
    }} }, &output.writer);
    try std.testing.expectEqualStrings(
        @embedFile("testdata/emitter/integer_primary_key.expect.sql"),
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
            .columns = &.{.{ .dsl_name = "key", .sql_name = "key", .type = storage_type, .primary_key = .standard }},
        }} }, &output.writer);
        const expected = switch (storage_type) {
            .text => @embedFile("testdata/emitter/text_primary_key.expect.sql"),
            .real => @embedFile("testdata/emitter/real_primary_key.expect.sql"),
            .blob => @embedFile("testdata/emitter/blob_primary_key.expect.sql"),
            .integer, .boolean, .datetime, .enumeration => unreachable,
        };
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
            .{ .dsl_name = "tenantId", .sql_name = "tenant\"id", .type = .integer, .primary_key = .standard },
            .{ .dsl_name = "value", .sql_name = "value", .type = .text },
            .{ .dsl_name = "key", .sql_name = "select", .type = .text, .primary_key = .standard },
        },
    }} }, &output.writer);
    try std.testing.expectEqualStrings(
        @embedFile("testdata/emitter/composite_primary_key.expect.sql"),
        output.written(),
    );
}

test "nullable primary keys fail before writing any table" {
    for ([_]resolved.PrimaryKey{ .standard, .allow_reuse }) |primary_key| {
        for ([_]bool{ false, true }) |composite| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            try std.testing.expectError(error.NullablePrimaryKey, emit(.{ .tables = &.{
                .{ .dsl_name = "Valid", .sql_name = "valid" },
                .{
                    .dsl_name = "Invalid",
                    .sql_name = "invalid",
                    .columns = &.{
                        .{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = primary_key, .nullable = true },
                        .{ .dsl_name = "other", .sql_name = "other", .type = .text, .primary_key = if (composite) .standard else .none },
                    },
                },
            } }, &output.writer));
            try std.testing.expectEqualStrings("", output.written());
        }
    }
}

test "integer primary keys with and without ID reuse" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emit(.{ .tables = &.{
        .{
            .dsl_name = "Book",
            .sql_name = "book",
            .columns = &.{
                .{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .allow_reuse },
                .{ .dsl_name = "title", .sql_name = "title", .type = .text },
            },
        },
        .{
            .dsl_name = "Author",
            .sql_name = "author",
            .columns = &.{
                .{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard },
                .{ .dsl_name = "name", .sql_name = "name", .type = .text },
            },
        },
    } }, &output.writer);
    try std.testing.expectEqualStrings(
        @embedFile("testdata/emitter/allow_id_reuse.expect.sql"),
        output.written(),
    );
}

test "ID reuse on non-integer primary keys fails before writing" {
    for ([_]resolved.StorageType{ .text, .real, .blob, .datetime }) |storage_type| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectError(error.InvalidIdReuse, emit(.{ .tables = &.{
            .{ .dsl_name = "Valid", .sql_name = "valid" },
            .{
                .dsl_name = "Invalid",
                .sql_name = "invalid",
                .columns = &.{.{ .dsl_name = "id", .sql_name = "id", .type = storage_type, .primary_key = .allow_reuse }},
            },
        } }, &output.writer));
        try std.testing.expectEqualStrings("", output.written());
    }
}

test "ID reuse on either composite key component fails before writing" {
    for (0..2) |reuse_index| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectError(error.InvalidIdReuse, emit(.{ .tables = &.{
            .{ .dsl_name = "Valid", .sql_name = "valid" },
            .{
                .dsl_name = "Invalid",
                .sql_name = "invalid",
                .columns = &.{
                    .{ .dsl_name = "first", .sql_name = "first", .type = .integer, .primary_key = if (reuse_index == 0) .allow_reuse else .standard },
                    .{ .dsl_name = "second", .sql_name = "second", .type = .integer, .primary_key = if (reuse_index == 1) .allow_reuse else .standard },
                },
            },
        } }, &output.writer));
        try std.testing.expectEqualStrings("", output.written());
    }
}
