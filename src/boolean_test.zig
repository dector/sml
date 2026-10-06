const std = @import("std");
const parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");

fn booleanPipeline(allocator: std.mem.Allocator) !void {
    // Both arenas must be independent of the source and of each other.
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/boolean.pzl"));
    var syntax = parser.parse(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(source);
        return error.ExpectedSchema;
    }
    try std.testing.expectEqualStrings("true", syntax.schema.schema.tables[0].fields[1].default.?.boolean.text);
    try std.testing.expectEqualStrings("false", syntax.schema.schema.tables[0].fields[2].default.?.boolean.text);
    var semantic = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(source);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(source);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    try std.testing.expect(semantic.schema.schema.tables[0].columns[1].default.?.boolean);
    try std.testing.expect(!semantic.schema.schema.tables[0].columns[2].default.?.boolean);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/boolean.expect.sql"), sql.written());
}

test "Boolean source to SQL fixture and ownership" {
    try booleanPipeline(std.testing.allocator);
}

test "Boolean pipeline reclaims every allocation failure" {
    // Arena growth must not depend on whether backing allocations can resize
    // in place; model layout changes otherwise make failure counts unstable.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), booleanPipeline, .{});
}

test "Boolean tokens preserve spelling spans and identifier boundaries" {
    const source = "true false trueValue false_ TRUE";
    var scanner = tokenizer.Tokenizer.init(source);
    for ([_]tokenizer.Kind{ .boolean, .boolean, .identifier, .identifier, .identifier }) |kind| {
        const value = scanner.next().token;
        try std.testing.expectEqual(kind, value.kind);
        try std.testing.expectEqualStrings(value.text, source[value.span.start..value.span.end]);
    }
    for ([_][]const u8{ "true {}", "false {}", "T {\n true bool\n}\n", "T {\n false bool\n}\n", "T {\n v true\n}\n" }) |text| {
        const result = try parser.parse(std.testing.allocator, text);
        try std.testing.expect(result == .diagnostic);
    }
}

fn rejectSource(allocator: std.mem.Allocator, source: []const u8, category: resolver.Category, offending: []const u8) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(category, result.diagnostic.category);
    try std.testing.expectEqualStrings(offending, source[result.diagnostic.span.start..result.diagnostic.span.end]);
}

test "Boolean literal compatibility and key diagnostics" {
    for ([_][]const u8{ "0", "1", "1.0", "'true'", "null" }) |literal| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n v bool({s})\n}}\n", .{literal});
        defer std.testing.allocator.free(source);
        try rejectSource(std.testing.allocator, source, .invalid_default, literal);
    }
    for ([_][]const u8{ "int", "real", "str", "blob" }) |name| {
        for ([_][]const u8{ "true", "false" }) |literal| {
            const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n v {s}({s})\n}}\n", .{ name, literal });
            defer std.testing.allocator.free(source);
            try rejectSource(std.testing.allocator, source, .invalid_default, literal);
        }
    }
    try rejectSource(std.testing.allocator, "T {\n !v bool?\n}\n", .nullable_primary_key, "bool?");
    try rejectSource(std.testing.allocator, "T {\n !v bool =\n   #allow reuse\n}\n", .invalid_primary_key, "bool");
    try rejectSource(std.testing.allocator, "T {\n v bool =\n   #allow reuse\n}\n", .invalid_id_reuse, "#allow reuse");
    for ([_][]const u8{
        "T {\n !v bool\n}\n",
        "T {\n !v bool(false)\n}\n",
        "T {\n !v bool\n !scope int\n}\n",
        "T {\n !scope int\n !v bool(true)\n}\n",
        "T {\n !first bool\n !second bool\n}\n",
    }) |source| try rejectSource(std.testing.allocator, source, .invalid_primary_key, "bool");
    try rejectSource(std.testing.allocator, "T {\n v boolean\n}\n", .unknown_type, "boolean");
}

fn booleanDiagnostic(allocator: std.mem.Allocator) !void {
    try rejectSource(allocator, "--- docs\nT {\n v bool(true)\n bad bool('wrong')\n}\n", .invalid_default, "'wrong'");
}

test "Boolean semantic failure reclaims every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, booleanDiagnostic, .{});
}

test "manually constructed Boolean tokens must be valid" {
    for ([_][]const u8{ "TRUE", "False", "1", "" }) |text| {
        const token: parsed.Token = .{ .text = text, .span = .{ .start = 3, .end = 7 } };
        const result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{.{
            .name = .{ .text = "T", .span = token.span },
            .span = token.span,
            .fields = &.{.{
                .name = .{ .text = "v", .span = token.span },
                .type = .{ .name = .{ .text = "bool", .span = token.span }, .span = token.span },
                .span = token.span,
                .default = .{ .boolean = token },
            }},
        }} });
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(resolver.Category.invalid_literal, result.diagnostic.category);
        try std.testing.expectEqual(token.span, result.diagnostic.span);
    }
}

test "emitter validates Boolean default compatibility before writing" {
    const cases = [_]struct { type: resolved.StorageType, value: resolved.Default }{
        .{ .type = .boolean, .value = .{ .integer = 1 } },
        .{ .type = .boolean, .value = .{ .real = 1 } },
        .{ .type = .boolean, .value = .{ .text = "true" } },
        .{ .type = .boolean, .value = .{ .blob = "1" } },
        .{ .type = .boolean, .value = .null_value },
        .{ .type = .integer, .value = .{ .boolean = true } },
        .{ .type = .real, .value = .{ .boolean = false } },
        .{ .type = .text, .value = .{ .boolean = true } },
        .{ .type = .blob, .value = .{ .boolean = false } },
    };
    for (cases) |case| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        try std.testing.expectError(error.InvalidDefault, emitter.emit(.{ .tables = &.{
            .{ .dsl_name = "Valid", .sql_name = "valid" },
            .{ .dsl_name = "T", .sql_name = "t", .columns = &.{.{ .dsl_name = "v", .sql_name = "v", .type = case.type, .default = case.value }} },
        } }, &sql.writer));
        try std.testing.expectEqualStrings("", sql.written());
    }
}

test "emitter rejects single and composite Boolean keys before any writes" {
    for ([_]resolved.PrimaryKey{ .standard, .allow_reuse }) |policy| {
        for ([_]bool{ false, true }) |composite| {
            var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer sql.deinit();
            const columns = [_]resolved.Column{
                .{ .dsl_name = "v", .sql_name = "v", .type = .boolean, .primary_key = policy, .default = .{ .boolean = false } },
                .{ .dsl_name = "scope", .sql_name = "scope", .type = .integer, .primary_key = .standard },
            };
            try std.testing.expectError(error.InvalidPrimaryKey, emitter.emit(.{ .tables = &.{
                .{ .dsl_name = "Valid", .sql_name = "valid" },
                .{ .dsl_name = "T", .sql_name = "t", .columns = columns[0..(if (composite) @as(usize, 2) else 1)] },
            } }, &sql.writer));
            try std.testing.expectEqualStrings("", sql.written());
        }
    }
}

fn invalidBooleanKey(allocator: std.mem.Allocator) !void {
    try rejectSource(allocator, "--- docs\nT {\n !scope int\n !v bool(false)\n}\n", .invalid_primary_key, "bool");
}

test "Boolean key diagnostics reclaim every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, invalidBooleanKey, .{});
}
