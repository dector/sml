const std = @import("std");
const resolver = @import("expression_resolver.zig");
const parser = @import("expression_parser.zig");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");
const a = std.testing.allocator;
const table: resolved.Table = .{ .dsl_name = "Event", .sql_name = "event", .columns = &.{
    .{ .dsl_name = "startAt", .sql_name = "start_at", .type = .datetime },
    .{ .dsl_name = "endAt", .sql_name = "exact SQL end", .type = .datetime, .nullable = true },
} };

fn run(allocator: std.mem.Allocator, source: []const u8, context: resolver.Context) !resolver.Result {
    var syntax = try parser.parse(a, source);
    defer syntax.expression.deinit();
    return resolver.resolve(allocator, syntax.expression.expression, context);
}

fn diagnostic(source: []const u8, context: resolver.Context, category: resolver.Category, start: usize, end: usize) !void {
    const result = try run(a, source, context);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(category, result.diagnostic.category);
    try std.testing.expectEqualDeep(parsed.Span{ .start = start, .end = end }, result.diagnostic.span);
    try std.testing.expect(result.diagnostic.message.len > 0);
}

test "table DSL lookup uses exact SQL override and field scope binds only underscore" {
    var result = try run(a, "!(endAt >= startAt)", .{ .table = table });
    defer result.expression.deinit();
    const expression = result.expression.expression;
    const binary = expression.kind.unary.operand.kind.grouping.kind.binary;
    try std.testing.expectEqualStrings("exact SQL end", binary.left.kind.identifier.sql_name);
    try std.testing.expectEqualStrings("start_at", binary.right.kind.identifier.sql_name);
    try std.testing.expectEqual(resolved.StorageType.datetime, binary.left.type_info.?.type);
    try std.testing.expect(expression.type_info.?.nullable);
    try std.testing.expectEqual(resolved.StorageType.boolean, expression.type_info.?.type);

    var field = try run(a, "(_ == _) || !(_ < _)", .{ .table = table, .field_index = 1 });
    defer field.expression.deinit();
    const repeated = field.expression.expression.kind.binary;
    try std.testing.expectEqualStrings("exact SQL end", repeated.left.kind.grouping.kind.binary.left.kind.current_value.sql_name);
    try std.testing.expectEqualStrings("exact SQL end", repeated.right.kind.unary.operand.kind.grouping.kind.binary.right.kind.current_value.sql_name);
    try std.testing.expect(repeated.left.kind.grouping.kind.binary.right.type_info.?.nullable);
    try diagnostic("endAt", .{ .table = table, .field_index = 0 }, .invalid_reference_scope, 0, 5);
    try diagnostic("_", .{ .table = table }, .invalid_reference_scope, 0, 1);
    try diagnostic("unknown", .{ .table = table }, .unknown_reference, 0, 7);
    try diagnostic("start_at", .{ .table = table }, .unknown_reference, 0, 8);
    try diagnostic("true", .{ .table = table, .field_index = 2 }, .invalid_context, 0, 4);
    try diagnostic("true", .{ .table = table, .field_index = std.math.maxInt(usize) }, .invalid_context, 0, 4);
}

test "resolved names text and raw SQL outlive source syntax and context" {
    const source = try a.dupe(u8, "endAt == 'it''s' && `endAt > 0`");
    const sql_name = try a.dupe(u8, "owned SQL name");
    var columns = [_]resolved.Column{.{ .dsl_name = "endAt", .sql_name = sql_name, .type = .text }};
    var result = try run(a, source, .{ .table = .{ .dsl_name = "T", .sql_name = "t", .columns = &columns } });
    defer result.expression.deinit();
    @memset(source, 'X');
    @memset(sql_name, 'X');
    a.free(source);
    a.free(sql_name);
    const binary = result.expression.expression.kind.binary;
    try std.testing.expectEqualStrings("owned SQL name", binary.left.kind.binary.left.kind.identifier.sql_name);
    try std.testing.expectEqualStrings("it's", binary.left.kind.binary.right.kind.text);
    try std.testing.expectEqualStrings("endAt > 0", binary.right.kind.raw_sql);
    try std.testing.expect(binary.right.type_info == null);
}

test "literal conversions preserve original decimal spelling and exact hash delimiters" {
    var integer = try run(a, "-001", .{ .table = table });
    defer integer.expression.deinit();
    try std.testing.expectEqual(@as(i64, -1), integer.expression.expression.kind.integer);
    var real = try run(a, "001.250", .{ .table = table });
    defer real.expression.deinit();
    try std.testing.expectEqual(@as(f64, 1.25), real.expression.expression.kind.real);
    var text = try run(a, "##'a'#b'###c'##", .{ .table = table });
    defer text.expression.deinit();
    try std.testing.expectEqualStrings("a'#b'###c", text.expression.expression.kind.text);
    var sql = try run(a, "##`a`#b`###c`##", .{ .table = table });
    defer sql.expression.deinit();
    try std.testing.expectEqualStrings("a`#b`###c", sql.expression.expression.kind.raw_sql);
    var boolean = try run(a, "false", .{ .table = table });
    defer boolean.expression.deinit();
    try std.testing.expect(!boolean.expression.expression.kind.boolean);
    var null_value = try run(a, "null", .{ .table = table });
    defer null_value.expression.deinit();
    try std.testing.expect(null_value.expression.expression.type_info == null);
    try diagnostic("1 == 'x'", .{ .table = table }, .incompatible_operands, 0, 8);
}

fn leaf(comptime tag: std.meta.Tag(@FieldType(parsed.Expression, "kind")), text: []const u8) parsed.Expression {
    return .{ .kind = @unionInit(@FieldType(parsed.Expression, "kind"), @tagName(tag), parsed.Token{ .text = text, .span = .{ .start = 3, .end = 3 + text.len } }), .span = .{ .start = 3, .end = 3 + text.len } };
}

test "manually built malformed tokens diagnose at leaf token span" {
    const cases = [_]parsed.Expression{
        leaf(.integer, "9223372036854775808"),
        leaf(.integer, "1_2"),
        leaf(.integer, "+1"),
        leaf(.integer, ""),
        leaf(.real, "nan"),
        leaf(.real, "1e2"),
        leaf(.real, "1."),
        leaf(.text, "'a'b'"),
        leaf(.text, "##'bad'#"),
        leaf(.text, "#'a'#tail'#"),
        leaf(.text, "##'a'###"),
        leaf(.raw_sql, "`a`tail`"),
        leaf(.raw_sql, "##`a`###"),
        leaf(.raw_sql, "``"),
        leaf(.raw_sql, "`a\x00b`"),
        leaf(.boolean, "TRUE"),
        leaf(.null_value, "NULL"),
    };
    for (cases) |input| {
        const result = try resolver.resolve(a, input, .{ .table = table });
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(resolver.Category.invalid_literal, result.diagnostic.category);
        try std.testing.expectEqualDeep(input.span, result.diagnostic.span);
    }
    var huge: [403]u8 = undefined;
    @memset(huge[0..400], '9');
    @memcpy(huge[400..], ".00");
    const overflow = try resolver.resolve(a, leaf(.real, &huge), .{ .table = table });
    try std.testing.expectEqual(resolver.Category.invalid_literal, overflow.diagnostic.category);
    try std.testing.expectEqualStrings("real literal must be finite", overflow.diagnostic.message);
    const multiline = try resolver.resolve(a, leaf(.text, "'a\nb'"), .{ .table = table });
    try std.testing.expectEqual(resolver.Category.unsupported_multiline, multiline.diagnostic.category);
    const bad_identifier = try resolver.resolve(a, leaf(.identifier, "not a name"), .{ .table = table });
    try std.testing.expectEqual(resolver.Category.invalid_identifier, bad_identifier.diagnostic.category);
    const bad_current = try resolver.resolve(a, leaf(.current_value, "x"), .{ .table = table, .field_index = 0 });
    try std.testing.expectEqual(resolver.Category.invalid_identifier, bad_current.diagnostic.category);
}

test "structural depth 256 accepted 257 rejected even for manual and cyclic trees" {
    var nodes: [258]parsed.Expression = undefined;
    nodes[0] = leaf(.boolean, "true");
    for (nodes[1..], 1..) |*node, i| node.* = .{ .kind = .{ .grouping = &nodes[i - 1] }, .span = .{ .start = i, .end = i + 1 } };
    var accepted = try resolver.resolve(a, nodes[256], .{ .table = table });
    defer accepted.expression.deinit();
    const rejected = try resolver.resolve(a, nodes[257], .{ .table = table });
    try std.testing.expectEqual(resolver.Category.excessive_depth, rejected.diagnostic.category);
    try std.testing.expectEqualDeep(nodes[0].span, rejected.diagnostic.span);
    var cycle: parsed.Expression = undefined;
    cycle = .{ .kind = .{ .unary = .{ .operator = .logical_not, .operand = &cycle } }, .span = .{ .start = 4, .end = 5 } };
    const cyclic = try resolver.resolve(a, cycle, .{ .table = table });
    try std.testing.expectEqual(resolver.Category.excessive_depth, cyclic.diagnostic.category);
}

test "null comparisons are deferred and logical null is not Boolean" {
    const operators = [_][]const u8{ "==", "!=", "<", "<=", ">", ">=", "&&", "||" };
    inline for (operators) |operator| {
        const source = "null " ++ operator ++ " true";
        const logical = comptime std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "||");
        try diagnostic(source, .{ .table = table }, if (logical) .incompatible_operands else .unsupported_null_comparison, 0, if (logical) 4 else source.len);
    }
    // The right child must be resolved even if the left is trusted SQL.
    try diagnostic("`trusted` == missing", .{ .table = table }, .unknown_reference, 13, 20);
}

fn fieldAllocationCase(allocator: std.mem.Allocator) !void {
    var result = try run(allocator, "(_ == _) && !(_ < _)", .{ .table = table, .field_index = 1 });
    defer result.expression.deinit();
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var result = try run(allocator, "!(endAt == '2000-02-29T00:00:00Z') || `trusted` == ##'raw'##", .{ .table = table });
    defer result.expression.deinit();
}

fn failureAllocationCase(allocator: std.mem.Allocator) !void {
    const result = try run(allocator, "endAt == '2000-01-01T00:00:00Z' && missing", .{ .table = table });
    try std.testing.expect(result == .diagnostic);
}

const typed_table: resolved.Table = .{ .dsl_name = "Types", .sql_name = "types", .columns = &.{
    .{ .dsl_name = "i", .sql_name = "i", .type = .integer },
    .{ .dsl_name = "r", .sql_name = "r", .type = .real },
    .{ .dsl_name = "s", .sql_name = "s", .type = .text },
    .{ .dsl_name = "e", .sql_name = "e", .type = .enumeration },
    .{ .dsl_name = "d", .sql_name = "d", .type = .datetime, .nullable = true },
    .{ .dsl_name = "b", .sql_name = "b", .type = .boolean, .nullable = true },
    .{ .dsl_name = "blob", .sql_name = "blob", .type = .blob },
} };

test "strict logical family matrix with trusted SQL and nullable propagation" {
    const context: resolver.Context = .{ .table = typed_table };
    const accepted = [_][]const u8{
        "i == r",       "r >= i",                       "1 < 1.5",                     "s == e",    "e < s",         "e == 'outside enum'",
        "d == d",       "d < ('2000-02-29T23:59:59Z')", "'2000-01-01T00:00:00Z' >= d", "b != true", "blob == blob",  "blob != (blob)",
        "!b",           "b && true",                    "false || b",                  "!`opaque`", "`opaque` && b", "i == `opaque`",
        "`opaque` < d", "blob == `opaque`",
    };
    for (accepted) |source| {
        var result = try run(a, source, context);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
        try std.testing.expectEqual(resolved.StorageType.boolean, result.expression.expression.type_info.?.type);
        try std.testing.expect(resolver.validateCheckResult(&result.expression.expression) == null);
    }
    const rejected = [_][]const u8{
        "i == s", "s == b",    "b == 1",    "true < false",  "blob < blob",     "blob == s",
        "d == s", "d == e",    "d == i",    "!1",            "!s",              "!d",
        "!blob",  "i && true", "true || s", "`opaque` && 1", "blob < `opaque`", "`opaque` > b",
    };
    for (rejected) |source| {
        const result = try run(a, source, context);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(resolver.Category.incompatible_operands, result.diagnostic.category);
    }
    for ([_][]const u8{ "b && true", "false || b", "!b", "d == d", "d > `opaque`", "true && `opaque`" }) |source| {
        var result = try run(a, source, context);
        defer result.expression.deinit();
        try std.testing.expect(result.expression.expression.type_info.?.nullable);
    }
    var nonnullable = try run(a, "i == r && true", context);
    defer nonnullable.expression.deinit();
    try std.testing.expect(!nonnullable.expression.expression.type_info.?.nullable);
    try diagnostic("d == '1900-02-29T00:00:00Z'", context, .invalid_literal, 5, 27);
    try diagnostic("'bad' < d", context, .invalid_literal, 0, 5);
    try diagnostic("d == '2000-01-01'", context, .invalid_literal, 5, 17);
    try diagnostic("(null) == `opaque`", context, .unsupported_null_comparison, 0, 18);
}

test "CHECK root validation is separate from scalar resolution" {
    const context: resolver.Context = .{ .table = typed_table };
    for ([_][]const u8{ "1", "1.0", "'text'", "d", "e", "blob", "(null)" }) |source| {
        var result = try run(a, source, context);
        defer result.expression.deinit();
        const failure = resolver.validateCheckResult(&result.expression.expression).?;
        try std.testing.expectEqual(resolver.Category.invalid_check_type, failure.category);
        try std.testing.expectEqualDeep(result.expression.expression.span, failure.span);
    }
    for ([_][]const u8{ "b", "(true)", "(`opaque`)", "i < r" }) |source| {
        var result = try run(a, source, context);
        defer result.expression.deinit();
        try std.testing.expect(resolver.validateCheckResult(&result.expression.expression) == null);
    }
}

test "allocation failures and semantic failure after allocations reclaim arena" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
    try std.testing.checkAllAllocationFailures(a, fieldAllocationCase, .{});
    try std.testing.checkAllAllocationFailures(a, failureAllocationCase, .{});
}
