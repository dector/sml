const std = @import("std");
const emitter = @import("expression_emitter.zig");
const parser = @import("expression_parser.zig");
const resolver = @import("expression_resolver.zig");
const resolved = @import("model/resolved.zig");
const Expression = resolved.Expression;
const a = std.testing.allocator;
const span: @import("model/parsed.zig").Span = .{ .start = 0, .end = 0 };
const table: resolved.Table = .{ .dsl_name = "T", .sql_name = "t", .columns = &.{
    .{ .dsl_name = "a", .sql_name = "a\" SQL", .type = .boolean, .nullable = true },
    .{ .dsl_name = "b", .sql_name = "b SQL", .type = .boolean, .nullable = true },
} };

fn pipeline(allocator: std.mem.Allocator, source: []const u8, expected: []const u8) !void {
    // Fixtures encode NUL as \\0 to keep the TSV a plain text file.
    const decoded = try std.mem.replaceOwned(u8, allocator, source, "\\0", "\x00");
    defer allocator.free(decoded);
    var syntax = try parser.parse(allocator, decoded);
    try std.testing.expect(syntax == .expression);
    defer syntax.expression.deinit();
    var result = try resolver.resolve(allocator, syntax.expression.expression, .{
        .table = table,
        .field_index = if (std.mem.eql(u8, source, "_ != null")) 0 else null,
    });
    try std.testing.expect(result == .expression);
    defer result.expression.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    emitter.emit(result.expression.expression, &output.writer) catch |err| {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
    try std.testing.expectEqualStrings(expected, output.written());
}

test "standalone source parse resolve emit fixtures" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("testdata/expression/expressions.tsv"), '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        try pipeline(a, line[0..tab], line[tab + 1 ..]);
    }
}

test "pipeline allocation failures including allocating writer" {
    try std.testing.checkAllAllocationFailures(a, pipeline, .{ "a && !b || a == null", "((\"a\"\" SQL\" AND (NOT \"b SQL\")) OR (\"a\"\" SQL\" IS NULL))" });
}

fn invalid(expression: Expression, expected: emitter.Error) !void {
    var output = std.Io.Writer.Allocating.init(a);
    defer output.deinit();
    try std.testing.expectError(expected, emitter.emit(expression, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
}

test "preflight rejects unsafe atoms even in later children" {
    const good: Expression = .{ .kind = .{ .boolean = true }, .span = span };
    const bad = [_]Expression{
        .{ .kind = .{ .identifier = .{ .sql_name = "" } }, .span = span },
        .{ .kind = .{ .current_value = .{ .sql_name = "bad\x00name" } }, .span = span },
        .{ .kind = .{ .raw_sql = "" }, .span = span },
        .{ .kind = .{ .raw_sql = "1\x00" }, .span = span },
        .{ .kind = .{ .real = std.math.inf(f64) }, .span = span },
        .{ .kind = .{ .real = std.math.nan(f64) }, .span = span },
    };
    const errors = [_]emitter.Error{ error.InvalidIdentifier, error.InvalidIdentifier, error.InvalidRawSql, error.InvalidRawSql, error.InvalidLiteral, error.InvalidLiteral };
    for (bad, errors) |node, err| {
        try invalid(.{ .kind = .{ .binary = .{ .operator = .logical_and, .left = &good, .right = &node } }, .span = span }, err);
    }
}

test "unlowered grouped null comparison and malformed IS fail" {
    const null_node: Expression = .{ .kind = .null_value, .span = span };
    const grouped: Expression = .{ .kind = .{ .grouping = &null_node }, .span = span };
    const good: Expression = .{ .kind = .{ .boolean = true }, .span = span };
    for ([_]@import("model/resolved_expression.zig").BinaryOperator{ .equal, .not_equal, .less_than, .greater_than_or_equal }) |operator| {
        try invalid(.{ .kind = .{ .binary = .{ .operator = operator, .left = &good, .right = &grouped } }, .span = span }, error.InvalidExpression);
    }
    try invalid(.{ .kind = .{ .binary = .{ .operator = .is_null, .left = &good, .right = &good } }, .span = span }, error.InvalidExpression);
}

test "structural depth boundary and cyclic input preflight" {
    var nodes: [258]Expression = undefined;
    nodes[0] = .{ .kind = .{ .boolean = true }, .span = span };
    for (nodes[1..], 1..) |*node, i| node.* = .{ .kind = .{ .grouping = &nodes[i - 1] }, .span = span };
    var output = std.Io.Writer.Allocating.init(a);
    defer output.deinit();
    try emitter.emit(nodes[256], &output.writer);
    try invalid(nodes[257], error.ExcessiveDepth);
    var cycle: Expression = .{ .kind = .null_value, .span = span };
    cycle.kind = .{ .grouping = &cycle };
    try invalid(cycle, error.ExcessiveDepth);
}

test "fixed writer failure propagates" {
    var buffer: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, emitter.emit(.{ .kind = .{ .text = "too long" }, .span = span }, &writer));
}
