//! SQLite expression generation, shared by standalone expressions and CHECKs.
const std = @import("std");
const resolved = @import("model/resolved.zig");
const model = @import("model/resolved_expression.zig");
const sql = @import("sql_writer.zig");

pub const max_depth = 256;
pub const Error = std.Io.Writer.Error || error{ InvalidIdentifier, InvalidLiteral, InvalidRawSql, InvalidExpression, ExcessiveDepth };

/// Preflight the entire tree before writing. Scalars are permitted; operand and
/// CHECK-root typing belong to the resolver. Raw SQL is trusted, not rewritten
/// or syntax-validated. Writer failures may leave partial output. Caller flushes.
pub fn preflight(expression: resolved.Expression) Error!void {
    try validate(&expression, 0);
}

pub fn emit(expression: resolved.Expression, writer: *std.Io.Writer) Error!void {
    try preflight(expression);
    try write(&expression, writer);
}

fn validEnum(value: anytype) bool {
    inline for (std.meta.tags(@TypeOf(value))) |tag| {
        if (@backingInt(value) == @backingInt(tag)) return true;
    }
    return false;
}

fn validate(expression: *const resolved.Expression, depth: usize) Error!void {
    if (depth > max_depth) return error.ExcessiveDepth;
    if (expression.type_info) |info| {
        if (!validEnum(info.type)) return error.InvalidExpression;
    }
    // Validate tags before switching, including directly constructed models.
    if (!validEnum(std.meta.activeTag(expression.kind))) return error.InvalidExpression;
    switch (expression.kind) {
        .real => |number| if (!std.math.isFinite(number)) return error.InvalidLiteral,
        .identifier, .current_value => |reference| {
            if (reference.sql_name.len == 0 or std.mem.indexOfScalar(u8, reference.sql_name, 0) != null)
                return error.InvalidIdentifier;
        },
        .raw_sql => |text| {
            if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidRawSql;
        },
        .grouping => |child| try validate(child, depth + 1),
        .unary => |unary| {
            if (!validEnum(unary.operator)) return error.InvalidExpression;
            try validate(unary.operand, depth + 1);
        },
        .binary => |binary| {
            if (!validEnum(binary.operator)) return error.InvalidExpression;
            try validate(binary.left, depth + 1);
            try validate(binary.right, depth + 1);
            const has_null = isNull(binary.left) or isNull(binary.right);
            switch (binary.operator) {
                .is_null, .is_not_null => if (!has_null) return error.InvalidExpression,
                .equal, .not_equal, .less_than, .less_than_or_equal, .greater_than, .greater_than_or_equal => if (has_null) return error.InvalidExpression,
                else => {},
            }
        },
        else => {},
    }
}

// Only called after all children passed the depth guard (also bounds cycles).
fn isNull(expression: *const resolved.Expression) bool {
    var node = expression;
    while (node.kind == .grouping) node = node.kind.grouping;
    return node.kind == .null_value;
}

fn write(expression: *const resolved.Expression, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (expression.kind) {
        .integer => |number| try writer.print("{d}", .{number}),
        .real => |number| try writer.print("{d}", .{number}),
        .text => |text| try sql.writeText(writer, text),
        .boolean => |value| try writer.writeAll(if (value) "1" else "0"),
        .null_value => try writer.writeAll("NULL"),
        .identifier, .current_value => |reference| try sql.writeIdentifier(writer, reference.sql_name),
        .raw_sql => |text| {
            try writer.writeByte('(');
            try writer.writeAll(text);
            try writer.writeByte(')');
        },
        .grouping => |child| {
            try writer.writeByte('(');
            try write(child, writer);
            try writer.writeByte(')');
        },
        .unary => |unary| {
            try writer.writeAll("(NOT ");
            try write(unary.operand, writer);
            try writer.writeByte(')');
        },
        .binary => |binary| {
            try writer.writeByte('(');
            try write(binary.left, writer);
            try writer.writeAll(switch (binary.operator) {
                .equal => " = ",
                .not_equal => " != ",
                .less_than => " < ",
                .less_than_or_equal => " <= ",
                .greater_than => " > ",
                .greater_than_or_equal => " >= ",
                .logical_and => " AND ",
                .logical_or => " OR ",
                .is_null => " IS ",
                .is_not_null => " IS NOT ",
            });
            try write(binary.right, writer);
            try writer.writeByte(')');
        },
    }
}

test {
    _ = @import("expression_emitter_test.zig");
}
