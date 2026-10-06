const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");

test {
    _ = @import("check_extra_test.zig");
    _ = @import("table_check_test.zig");
}

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/checks.pzl"));
    var syntax = parser.parse(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(source);
        return error.ExpectedSchema;
    }
    const directives = syntax.schema.schema.tables[0].fields[0].directives;
    try std.testing.expectEqualStrings("? _ > 0", source[directives[0].span.start..directives[0].span.end]);
    const expr = directives[0].kind.check;
    try std.testing.expectEqualStrings("_ > 0", source[expr.span.start..expr.span.end]);
    var semantic = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(source);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(source);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    try std.testing.expectEqual(@as(usize, 2), semantic.schema.schema.tables[0].columns[0].checks.len);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/checks.expect.sql"), sql.written());
}

test "field checks source to SQL, byte spans, order and independent ownership" {
    try pipeline(std.testing.allocator);
}

test "field checks pipeline reclaims all allocation failures" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

fn rejectSyntax(source: []const u8, offending: []const u8, message: []const u8) !void {
    var result = try parser.parse(std.testing.allocator, source);
    if (result == .schema) {
        result.schema.deinit();
        return error.ExpectedDiagnostic;
    }
    const d = result.diagnostic;
    try std.testing.expectEqualStrings(offending, source[d.span.start..d.span.end]);
    try std.testing.expect(std.mem.indexOf(u8, d.message, message) != null);
}

test "field check scope, docs, body options, terminators and EOF diagnostics" {
    try rejectSyntax("T {\n? true\n}\n", "?", "field scope");
    try rejectSyntax("T {\na int {\n?? true\n}\n}\n", "?", "Table checks");
    try rejectSyntax("T {\na int {\n#check {\n}\n}\n}\n", "{", "Expected expression");
    try rejectSyntax("T {\na int {\n--- docs\n? _ > 0\n}\n}\n", "--- docs", "Unattached documentation");
    try rejectSyntax("T {\na int =\n  --- docs\n  #check _ > 0\n}\n", "--- docs", "Unattached documentation");
    try rejectSyntax("T {\na int {\n?", "", "expression");
    try rejectSyntax("T {\na int {\n? (_ >", "", "expression");
    try rejectSyntax("T {\na int {\n? _ > 0", "", "close field body");
    try rejectSyntax("T {\na int {\n? _ >\n0\n}\n}\n", "\n", "expression");
}

fn semanticFailure(allocator: std.mem.Allocator) !void {
    var syntax = try parser.parse(allocator, "--- table docs\nT {\n--- field docs\na str {\n? (_ != 'longer string literal')\n#check _ > null\n}\n}\n");
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
}

test "field checks semantic failures retain expression spans and messages" {
    for ([_]struct { expr: []const u8, offending: []const u8, message: []const u8 }{
        .{ .expr = "a > 0", .offending = "a", .message = "named references" },
        .{ .expr = "_", .offending = "_", .message = "must be Boolean" },
        .{ .expr = "0", .offending = "0", .message = "must be Boolean" },
        .{ .expr = "!_", .offending = "_", .message = "Boolean" },
        .{ .expr = "_ > null", .offending = "_ > null", .message = "null" },
    }) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\na int {{\n#check {s}\n}}\n}}\n", .{case.expr});
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        const d = result.diagnostic;
        try std.testing.expectEqual(resolver.Category.invalid_check, d.category);
        try std.testing.expectEqualStrings(case.offending, source[d.span.start..d.span.end]);
        try std.testing.expect(std.mem.indexOf(u8, d.message, case.message) != null);
    }
    // Arena growth can resize in-place depending on backing allocator state.
    // Disable resize/remap so the failure sweep has a stable allocation count.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), semanticFailure, .{});
}

test "manually built table checks resolve without columns" {
    const span: parsed.Span = .{ .start = 0, .end = 1 };
    var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{.{
        .name = .{ .text = "T", .span = span },
        .span = span,
        .directives = &.{.{ .span = span, .kind = .{ .check = .{ .span = span, .kind = .{ .boolean = .{ .text = "true", .span = span } } } } }},
    }} });
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.schema.schema.tables[0].checks.len);
}

test "schema emitter preflights every check before any SQL" {
    const span: parsed.Span = .{ .start = 0, .end = 0 };
    const cases = [_]struct { expression: resolved.Expression, err: emitter.Error }{
        .{ .expression = .{ .span = span, .kind = .{ .integer = 1 }, .type_info = .{ .type = .integer } }, .err = error.InvalidCheck },
        .{ .expression = .{ .span = span, .kind = .{ .integer = 1 }, .type_info = .{ .type = .boolean } }, .err = error.InvalidCheck },
        .{ .expression = .{ .span = span, .kind = .{ .real = std.math.inf(f64) } }, .err = error.InvalidLiteral },
        .{ .expression = .{ .span = span, .kind = .{ .raw_sql = "" } }, .err = error.InvalidRawSql },
        .{ .expression = .{ .span = span, .kind = .{ .current_value = .{ .sql_name = "bad\x00name" } }, .type_info = .{ .type = .boolean } }, .err = error.InvalidIdentifier },
    };
    for (cases) |case| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        try std.testing.expectError(case.err, emitter.emit(.{ .tables = &.{
            .{ .dsl_name = "ok", .sql_name = "ok" },
            .{ .dsl_name = "T", .sql_name = "t", .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .integer, .checks = &.{.{ .expression = case.expression }} }} },
        } }, &sql.writer));
        try std.testing.expectEqualStrings("", sql.written());
    }
}
