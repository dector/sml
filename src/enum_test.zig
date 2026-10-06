const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");

fn pipeline(backing: std.mem.Allocator) !void {
    // Arena growth must not depend on whether the backing allocator can remap.
    var vtable = backing.vtable.*;
    vtable.resize = std.mem.Allocator.noResize;
    vtable.remap = std.mem.Allocator.noRemap;
    const allocator: std.mem.Allocator = .{ .ptr = backing.ptr, .vtable = &vtable };
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/enum.sml"));
    var syntax = parser.parse(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(source);
        return error.ExpectedSchema;
    }
    const field = syntax.schema.schema.tables[0].fields[1];
    const value = field.directives[0].kind.of[3];
    try std.testing.expectEqualStrings("a--b", value.text);
    try std.testing.expectEqualStrings(value.text, source[value.span.start..value.span.end]);
    try std.testing.expectEqual(@intFromPtr(source.ptr) + value.span.start, @intFromPtr(value.text.ptr));
    var semantic = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(source);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(source);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    const columns = semantic.schema.schema.tables[0].columns;
    try std.testing.expectEqual(resolved.StorageType.enumeration, columns[1].type);
    try std.testing.expectEqualStrings("true", columns[1].default.?.text);
    try std.testing.expectEqualStrings("", columns[1].enum_values[4]);
    try std.testing.expectEqualStrings("a\x00雪", columns[3].default.?.text);
    // One explicit allocation avoids platform-dependent remap growth counts.
    var sql = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/enum.expect.sql"), sql.written());
}

test "enum pipeline spans borrowed tokens owned decoded arrays and OOM cleanup" {
    try pipeline(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pipeline, .{});
}

fn reject(allocator: std.mem.Allocator, source: []const u8, category: resolver.Category, spelling: []const u8) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const semantic = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(category, semantic.diagnostic.category);
    try std.testing.expectEqualStrings(spelling, source[semantic.diagnostic.span.start..semantic.diagnostic.span.end]);
}

test "enum sets defaults scope and primary key validation" {
    try reject(std.testing.allocator, "T {\n a enum\n}\n", .invalid_enum, "enum");
    try reject(std.testing.allocator, "T {\n a enum =\n   #of `\xc0\x80`\n}\n", .invalid_literal, "`\xc0\x80`");
    try reject(std.testing.allocator, "T {\n a enum =\n   #of a, `a`\n}\n", .invalid_enum, "`a`");
    try reject(std.testing.allocator, "T {\n a enum =\n   #of ``\n   #of #``#\n}\n", .invalid_enum, "#``#");
    try reject(std.testing.allocator, "T {\n a enum(missing) =\n   #of found\n}\n", .invalid_default, "missing");
    try reject(std.testing.allocator, "T {\n a enum(null) =\n   #of `null`\n}\n", .invalid_default, "null");
    try reject(std.testing.allocator, "T {\n a str =\n   #of a\n}\n", .invalid_directive_scope, "#of a");
    try reject(std.testing.allocator, "T {\n !a enum? =\n   #of a\n}\n", .nullable_primary_key, "enum?");
    try reject(std.testing.allocator, "T {\n !a enum =\n   #of a\n   #allow reuse\n}\n", .invalid_id_reuse, "#allow reuse");
    try reject(std.testing.allocator, "T {\n a enum =\n   #of a\n   #allow reuse\n}\n", .invalid_id_reuse, "#allow reuse");
}

fn diagnosticFailure(allocator: std.mem.Allocator) !void {
    try reject(allocator, "--- table\nT {\n --- field\n a enum =\n   #of `a`, b\n   #of #`a`#\n}\n", .invalid_enum, "#`a`#");
}

test "enum semantic diagnostics reclaim all allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, diagnosticFailure, .{});
}

test "enum contextual maximal words and existing adjacent comments" {
    var syntax = try parser.parse(std.testing.allocator, "T {\n s str--comment\n e enum(a--b) =\n   #of a--b, true, false, _ -- comment\n}\n");
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    try std.testing.expectEqualStrings("str", syntax.schema.schema.tables[0].fields[0].type.name.text);
    try std.testing.expectEqualStrings("a--b", syntax.schema.schema.tables[0].fields[1].default.?.enum_text.text);
    const sources = [_][]const u8{
        "T {\n e enum =\n   #of\n}\n",
        "T {\n e enum =\n   #of a,\n}\n",
        "T {\n e enum =\n   #of ,a\n}\n",
        "T {\n e enum =\n   #of a,,b\n}\n",
        "T {\n e enum =\n   #of a b\n}\n",
        "T {\n e enum =\n   #of null\n}\n",
        "T {\n e enum =\n   #of 'a'\n}\n",
        "T {\n e enum =\n   #of 1\n}\n",
        "T {\n #of a\n}\n",
        "T {\n e enum(1)\n}\n",
        "T {\n e enum(1.0)\n}\n",
        "T {\n e enum('a')\n}\n",
        "T {\n e enum(::now)\n}\n",
        "T {\n e enum[]\n}\n",
        "=> Status enum\n",
        "T {\n a-b str\n}\n",
        "T {\n e enum =\n   #of a,\n   b\n}\n",
    };
    for (sources) |source| {
        const result = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
    }
    try reject(std.testing.allocator, "T {\n e enum(a) =\n   #of a--comment\n}\n", .invalid_default, "a");
}

test "enum defaults preserve contextual words and exact decoded bytes" {
    for ([_][]const u8{ "true", "false", "_", "null-x", "_a-0", "a--b", "`null`", "``", "`it's ready`", "##`tick`#hash`##" }) |literal| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n a enum({s}) {{\n #of {s}, Case, case, `é`, `é`\n }}\n}}\n", .{ literal, literal });
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(semantic == .schema);
        defer semantic.schema.deinit();
        const column = semantic.schema.schema.tables[0].columns[0];
        try std.testing.expectEqualStrings(column.enum_values[0], column.default.?.text);
        try std.testing.expectEqual(@as(usize, 5), column.enum_values.len);
    }
}

fn syntaxFailure(allocator: std.mem.Allocator) !void {
    const result = try parser.parse(allocator, "--- docs\nT {\n a enum(a) =\n   #of a, b\n   #of `c`,\n}\n");
    try std.testing.expect(result == .diagnostic);
}

test "enum syntax failures reclaim accumulated member arrays" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, syntaxFailure, .{});
}

const token: parsed.Token = .{ .text = "a", .span = .{ .start = 0, .end = 1 } };

fn manual(value: ?parsed.Default, type_name: []const u8, members: []const parsed.Token) !void {
    const result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{.{
        .name = token,
        .span = token.span,
        .fields = &.{.{
            .name = token,
            .span = token.span,
            .type = .{ .name = .{ .text = type_name, .span = token.span }, .span = token.span },
            .default = value,
            .directives = &.{.{ .kind = .{ .of = members }, .span = token.span }},
        }},
    }} });
    try std.testing.expect(result == .diagnostic);
}

test "resolver validates manually built enum syntax" {
    try manual(null, "enum", &.{});
    try manual(null, "str", &.{token});
    try manual(null, "enum", &.{ token, token });
    for ([_][]const u8{ "null", "1bad", "a b", "a!", "é", "`bad", "#`a`##", "`\xc0\x80`", "`\xff`", "`\xed\xa0\x80`" }) |invalid|
        try manual(null, "enum", &.{.{ .text = invalid, .span = token.span }});
    for ([_]parsed.Default{
        .{ .text = .{ .text = "'a'", .span = token.span } },
        .{ .boolean = .{ .text = "true", .span = token.span } },
        .{ .integer = .{ .text = "1", .span = token.span } },
        .{ .real = .{ .text = "1.0", .span = token.span } },
        .{ .generator = .{ .text = "::now", .span = token.span } },
        .{ .raw_sql = .{ .text = "`a`", .span = token.span } },
        .{ .enum_text = .{ .text = "missing", .span = token.span } },
        .{ .null_value = .{ .text = "null", .span = token.span } },
    }) |value| try manual(value, "enum", &.{token});
    try manual(.{ .enum_text = token }, "str", &.{token});
}

test "emitter validates direct enum models before writing" {
    const cases = [_]struct { column: resolved.Column, err: emitter.Error }{
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration }, .err = error.InvalidEnum },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration, .enum_values = &.{ "a", "a" } }, .err = error.InvalidEnum },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .text, .enum_values = &.{"a"} }, .err = error.InvalidEnum },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration, .enum_values = &.{"\xc0\x80"}, .default = .{ .text = "\xc0\x80" } }, .err = error.InvalidEnum },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration, .enum_values = &.{"\xff"} }, .err = error.InvalidEnum },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration, .enum_values = &.{"a"}, .default = .{ .text = "b" } }, .err = error.InvalidDefault },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration, .enum_values = &.{"a"}, .default = .{ .integer = 1 } }, .err = error.InvalidDefault },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration, .enum_values = &.{"a"}, .default = .null_value }, .err = error.InvalidDefault },
        .{ .column = .{ .dsl_name = "a", .sql_name = "a", .type = .enumeration, .enum_values = &.{"a"}, .primary_key = .allow_reuse }, .err = error.InvalidIdReuse },
    };
    for (cases) |case| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        try std.testing.expectError(case.err, emitter.emit(.{ .tables = &.{
            .{ .dsl_name = "valid", .sql_name = "valid" },
            .{ .dsl_name = "bad", .sql_name = "bad", .columns = &.{case.column} },
        } }, &sql.writer));
        try std.testing.expectEqualStrings("", sql.written());
    }
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try emitter.emit(.{ .tables = &.{.{ .dsl_name = "a", .sql_name = "a", .columns = &.{.{
        .dsl_name = "a",
        .sql_name = "a",
        .type = .enumeration,
        .enum_values = &.{ "", "null", "雪\x00😀" },
        .default = .{ .raw_sql = "''" },
    }} }} }, &sql.writer);
    try std.testing.expect(std.mem.indexOf(u8, sql.written(), "DEFAULT ('')") != null);
}
