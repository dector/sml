const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/table_checks.sml"));
    var syntax = parser.parse(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(source);
        return error.ExpectedSchema;
    }
    const directives = syntax.schema.schema.tables[0].directives;
    try std.testing.expectEqual(@as(usize, 4), directives.len);
    try std.testing.expectEqualStrings("?? lower <= upper", source[directives[0].span.start..directives[0].span.end]);
    try std.testing.expectEqualStrings("lower <= upper", source[directives[0].kind.check.span.start..directives[0].kind.check.span.end]);
    try std.testing.expect(directives[1].kind == .name);
    var semantic = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(source);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(source);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    const table = semantic.schema.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.checks.len);
    try std.testing.expectEqualStrings("low\"value", table.checks[0].expression.kind.binary.left.kind.identifier.sql_name);
    try std.testing.expect(table.checks[0].expression.type_info.?.nullable);
    try std.testing.expectEqual(@as(usize, 1), table.columns[2].checks.len);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/table_checks.expect.sql"), sql.written());
}

test "table checks forward references, directive order, SQL names, independent ownership" {
    try pipeline(std.testing.allocator);
}

test "table checks pipeline allocation failures" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "table check syntax diagnostics have exact spans" {
    for ([_]struct { source: []const u8, offending: []const u8, message: []const u8 }{
        .{ .source = "T {\n? true\n}\n", .offending = "?", .message = "field scope" },
        .{ .source = "T {\na int {\n?? true\n}\n}\n", .offending = "?", .message = "table scope" },
        .{ .source = "T {\na int =\n  ?? true\n}\n", .offending = "?", .message = "table scope" },
        .{ .source = "T {\n--- docs\n?? true\n}\n", .offending = "--- docs", .message = "Unattached documentation" },
        .{ .source = "T {\n--- docs\n#check true\n}\n", .offending = "--- docs", .message = "Unattached documentation" },
        .{ .source = "T {\n#check {\n}\n", .offending = "{", .message = "Expected expression" },
        .{ .source = "T {\n??", .offending = "", .message = "expression" },
        .{ .source = "T {\n#check", .offending = "", .message = "expression" },
        .{ .source = "T {\n?? (true &&", .offending = "", .message = "expression" },
        .{ .source = "T {\n?? true", .offending = "", .message = "close table" },
    }) |case| {
        var result = try parser.parse(std.testing.allocator, case.source);
        if (result == .schema) {
            result.schema.deinit();
            return error.ExpectedDiagnostic;
        }
        try std.testing.expectEqualStrings(case.offending, case.source[result.diagnostic.span.start..result.diagnostic.span.end]);
        const expected_start = if (case.offending.len == 0) case.source.len else if (std.mem.eql(u8, case.message, "table scope")) std.mem.indexOf(u8, case.source, "??").? + 1 else std.mem.lastIndexOf(u8, case.source, case.offending).?;
        try std.testing.expectEqual(expected_start, result.diagnostic.span.start);
        try std.testing.expectEqual(expected_start + case.offending.len, result.diagnostic.span.end);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, case.message) != null);
    }
}

test "table check semantic errors preserve exact expression spans" {
    for ([_]struct { expr: []const u8, offending: []const u8, message: []const u8 }{
        .{ .expr = "_ > 0", .offending = "_", .message = "field scope" },
        .{ .expr = "missing == null", .offending = "missing", .message = "unknown DSL" },
        .{ .expr = "renamed == 0", .offending = "renamed", .message = "unknown DSL" },
        .{ .expr = "a", .offending = "a", .message = "must be Boolean" },
        .{ .expr = "0", .offending = "0", .message = "must be Boolean" },
        .{ .expr = "null", .offending = "null", .message = "must be Boolean" },
        .{ .expr = "a == flag", .offending = "a == flag", .message = "matching logical families" },
        .{ .expr = "a > null", .offending = "a > null", .message = "null" },
        .{ .expr = "stamp > '2024-01-01T00:00:00+01:00'", .offending = "'2024-01-01T00:00:00+01:00'", .message = "UTC" },
        .{ .expr = "stamp == a", .offending = "stamp == a", .message = "matching logical families" },
    }) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n?? {s}\na int {{\n#name `renamed`\n}}\nflag bool\nstamp datetime\n}}\n", .{case.expr});
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(resolver.Category.invalid_check, result.diagnostic.category);
        try std.testing.expectEqualStrings(case.offending, source[result.diagnostic.span.start..result.diagnostic.span.end]);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, case.message) != null);
    }
}

fn manual(allocator: std.mem.Allocator) !void {
    const span: parsed.Span = .{ .start = 0, .end = 1 };
    var result = try resolver.resolve(allocator, .{ .tables = &.{.{
        .name = .{ .text = "Empty", .span = span },
        .span = span,
        .directives = &.{.{ .span = span, .kind = .{ .check = .{ .span = span, .kind = .{ .boolean = .{ .text = "true", .span = span } } } } }},
    }} });
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(result.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    // Like a bare empty table, a checks-only table is an intentional SQL skeleton.
    try std.testing.expectEqualStrings("PRAGMA foreign_keys = ON;\n\nCREATE TABLE \"empty\" (\n  CHECK (1)\n) STRICT;\n", sql.written());
}

test "manual zero-column table checks and OOM preserve skeleton policy" {
    try manual(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), manual, .{});
}

test "table checks cannot reference absent columns and field checks cannot reference peers" {
    for ([_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "T {\n?? peer > 0\n}\n", .message = "unknown DSL field name" },
        .{ .source = "T {\na int {\n? peer > 0\n}\npeer int\n}\n", .message = "named references are only allowed in table scope" },
    }) |case| {
        var syntax = try parser.parse(std.testing.allocator, case.source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        const start = std.mem.indexOf(u8, case.source, "peer").?;
        try std.testing.expectEqual(parsed.Span{ .start = start, .end = start + 4 }, result.diagnostic.span);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, case.message) != null);
    }
}

test "table checks preflight before any writer output" {
    const span: parsed.Span = .{ .start = 0, .end = 0 };
    for ([_]struct { expression: resolved.Expression, err: emitter.Error }{
        .{ .expression = .{ .span = span, .kind = .{ .integer = 1 }, .type_info = .{ .type = .boolean } }, .err = error.InvalidCheck },
        .{ .expression = .{ .span = span, .kind = .{ .raw_sql = "" } }, .err = error.InvalidRawSql },
        .{ .expression = .{ .span = span, .kind = .{ .identifier = .{ .sql_name = "bad\x00name" } }, .type_info = .{ .type = .boolean } }, .err = error.InvalidIdentifier },
        .{ .expression = .{ .span = span, .kind = .{ .real = std.math.inf(f64) } }, .err = error.InvalidLiteral },
    }) |case| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        try std.testing.expectError(case.err, emitter.emit(.{ .tables = &.{
            .{ .dsl_name = "ok", .sql_name = "ok" },
            .{ .dsl_name = "T", .sql_name = "t", .checks = &.{.{ .expression = case.expression }} },
        } }, &sql.writer));
        try std.testing.expectEqualStrings("", sql.written());
    }
}
