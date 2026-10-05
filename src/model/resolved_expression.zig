//! Resolved expression trees. Decoded text, exact SQL names, raw SQL, and
//! child nodes are owned by the caller, typically a resolution arena. No
//! source buffer is required for their contents; spans still refer to it.
const std = @import("std");
const parsed = @import("parsed.zig");
const resolved = @import("resolved.zig");
const syntax = @import("parsed_expression.zig");

pub const UnaryOperator = syntax.UnaryOperator;
/// Resolved operators are separate from syntax. Null-literal equality lowers
/// to IS / IS NOT; operands (including grouping and source order) are preserved.
pub const BinaryOperator = enum {
    equal,
    not_equal,
    less_than,
    less_than_or_equal,
    greater_than,
    greater_than_or_equal,
    logical_and,
    logical_or,
    is_null,
    is_not_null,
};

pub const TypeInfo = struct {
    type: resolved.StorageType,
    nullable: bool = false,
};

pub const Reference = struct {
    /// Resolved exact SQL name, after overrides, without SQL quoting.
    sql_name: []const u8,
};

pub const Expression = struct {
    kind: union(enum) {
        integer: i64,
        real: f64,
        text: []const u8,
        boolean: bool,
        null_value,
        identifier: Reference,
        /// Field-scope `_`, bound to that field's actual SQL name.
        current_value: Reference,
        /// Decoded contents, without backticks; never identifier-rewritten.
        raw_sql: []const u8,
        grouping: *const Expression,
        unary: struct {
            operator: UnaryOperator,
            operand: *const Expression,
        },
        binary: struct {
            operator: BinaryOperator,
            left: *const Expression,
            right: *const Expression,
        },
    },
    span: parsed.Span,
    /// Absent when no logical type is known (e.g. null or opaque raw SQL).
    /// SQL null propagation is separate from CHECK acceptance semantics.
    type_info: ?TypeInfo = null,
};

test "resolved references use owned exact SQL names and nullable type info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source_name = [_]u8{ 'e', 'n', 'd', ' ', 'a', 't' };
    const reference = try allocator.create(Expression);
    reference.* = .{
        .kind = .{ .identifier = .{ .sql_name = try allocator.dupe(u8, &source_name) } },
        .span = .{ .start = 0, .end = 6 },
        .type_info = .{ .type = .datetime, .nullable = true },
    };
    source_name[0] = 'X';
    const current = try allocator.create(Expression);
    current.* = .{
        .kind = .{ .current_value = .{ .sql_name = try allocator.dupe(u8, "start_override") } },
        .span = .{ .start = 9, .end = 10 },
        .type_info = .{ .type = .datetime },
    };
    const comparison: Expression = .{
        .kind = .{ .binary = .{ .operator = .greater_than, .left = reference, .right = current } },
        .span = .{ .start = 0, .end = 10 },
        .type_info = .{ .type = .boolean, .nullable = true },
    };
    try std.testing.expectEqualStrings("end at", comparison.kind.binary.left.kind.identifier.sql_name);
    try std.testing.expectEqualStrings("start_override", comparison.kind.binary.right.kind.current_value.sql_name);
    try std.testing.expect(reference.type_info.?.nullable);
    try std.testing.expect(!current.type_info.?.nullable);
    try std.testing.expectEqual(resolved.StorageType.boolean, comparison.type_info.?.type);
    try std.testing.expect(comparison.type_info.?.nullable);
}

test "resolved literals and raw SQL are independent of source spelling" {
    const span: parsed.Span = .{ .start = 2, .end = 9 };
    const nodes = [_]Expression{
        .{ .kind = .{ .integer = 1 }, .span = span, .type_info = .{ .type = .integer } },
        .{ .kind = .{ .real = 1.25 }, .span = span, .type_info = .{ .type = .real } },
        .{ .kind = .{ .text = "a\n" }, .span = span, .type_info = .{ .type = .text } },
        .{ .kind = .{ .boolean = true }, .span = span, .type_info = .{ .type = .boolean } },
        .{ .kind = .null_value, .span = span },
        .{ .kind = .{ .raw_sql = "_ > 0" }, .span = span },
    };
    try std.testing.expectEqual(@as(i64, 1), nodes[0].kind.integer);
    try std.testing.expectEqual(@as(f64, 1.25), nodes[1].kind.real);
    try std.testing.expectEqualStrings("a\n", nodes[2].kind.text);
    try std.testing.expect(nodes[3].kind.boolean);
    try std.testing.expect(nodes[4].kind == .null_value);
    try std.testing.expect(nodes[4].type_info == null);
    try std.testing.expectEqualStrings("_ > 0", nodes[5].kind.raw_sql);
    try std.testing.expect(nodes[5].type_info == null);
    for (nodes) |node| try std.testing.expectEqualDeep(span, node.span);
}
