//! Expression syntax only. Tokens borrow the source (including delimiters),
//! and child nodes belong to the caller, typically a syntax arena.
const std = @import("std");
const parsed = @import("parsed.zig");

pub const UnaryOperator = enum { logical_not };

/// The settled DSL subset deliberately excludes arithmetic.
pub const BinaryOperator = enum {
    equal,
    not_equal,
    less_than,
    less_than_or_equal,
    greater_than,
    greater_than_or_equal,
    logical_and,
    logical_or,
};

pub const Expression = struct {
    kind: union(enum) {
        integer: parsed.Token,
        real: parsed.Token,
        text: parsed.Token,
        boolean: parsed.Token,
        null_value: parsed.Token,
        identifier: parsed.Token,
        current_value: parsed.Token,
        raw_sql: parsed.Token,
        /// The node span includes both parentheses.
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
    /// Zero-based, end-exclusive span covering the entire expression.
    span: parsed.Span,
};

test "expression leaves borrow original spelling and spans" {
    const cases = [_]struct { text: []const u8, tag: std.meta.Tag(@FieldType(Expression, "kind")) }{
        .{ .text = "001", .tag = .integer },
        .{ .text = "001.250", .tag = .real },
        .{ .text = "\"a\\n\"", .tag = .text },
        .{ .text = "true", .tag = .boolean },
        .{ .text = "null", .tag = .null_value },
        .{ .text = "startsAt", .tag = .identifier },
        .{ .text = "_", .tag = .current_value },
        .{ .text = "`price > 0`", .tag = .raw_sql },
    };
    inline for (cases) |case| {
        const source = "  " ++ case.text ++ " ";
        const span: parsed.Span = .{ .start = 2, .end = source.len - 1 };
        const token: parsed.Token = .{ .text = source[span.start..span.end], .span = span };
        const node: Expression = .{ .kind = @unionInit(@FieldType(Expression, "kind"), @tagName(case.tag), token), .span = span };
        const leaf = @field(node.kind, @tagName(case.tag));
        try std.testing.expectEqualStrings(case.text, leaf.text);
        try std.testing.expect(leaf.text.ptr == source[2..].ptr);
        try std.testing.expectEqualDeep(span, leaf.span);
        try std.testing.expectEqualStrings(case.text, source[node.span.start..node.span.end]);
    }
}

test "arena expression tree preserves grouping and operator spans" {
    const source = "!(_ >= 001)";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const current = try allocator.create(Expression);
    current.* = .{ .kind = .{ .current_value = .{ .text = source[2..3], .span = .{ .start = 2, .end = 3 } } }, .span = .{ .start = 2, .end = 3 } };
    const literal = try allocator.create(Expression);
    literal.* = .{ .kind = .{ .integer = .{ .text = source[7..10], .span = .{ .start = 7, .end = 10 } } }, .span = .{ .start = 7, .end = 10 } };
    const comparison = try allocator.create(Expression);
    comparison.* = .{ .kind = .{ .binary = .{ .operator = .greater_than_or_equal, .left = current, .right = literal } }, .span = .{ .start = 2, .end = 10 } };
    const group = try allocator.create(Expression);
    group.* = .{ .kind = .{ .grouping = comparison }, .span = .{ .start = 1, .end = 11 } };
    const node: Expression = .{ .kind = .{ .unary = .{ .operator = .logical_not, .operand = group } }, .span = .{ .start = 0, .end = source.len } };
    try std.testing.expectEqualStrings(source, source[node.span.start..node.span.end]);
    try std.testing.expectEqualStrings("(_ >= 001)", source[group.span.start..group.span.end]);
    try std.testing.expectEqualStrings("_ >= 001", source[comparison.span.start..comparison.span.end]);
    try std.testing.expectEqual(UnaryOperator.logical_not, node.kind.unary.operator);
    try std.testing.expectEqual(BinaryOperator.greater_than_or_equal, node.kind.unary.operand.kind.grouping.kind.binary.operator);
    try std.testing.expectEqualStrings("001", comparison.kind.binary.right.kind.integer.text);
    try std.testing.expect(comparison.kind.binary.left == current);
}
