//! Owned reference/literal resolution. Operand compatibility is a later pass.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");
const model = @import("model/resolved_expression.zig");
const literals = @import("literal_decoder.zig");

pub const Category = enum {
    invalid_context,
    invalid_reference_scope,
    unknown_reference,
    invalid_literal,
    invalid_identifier,
    unsupported_multiline,
    excessive_depth,
};
pub const Diagnostic = struct { category: Category, span: parsed.Span, message: []const u8 };
pub const Context = struct { table: resolved.Table, field_index: ?usize = null };
pub const max_depth = 256;

pub const OwnedExpression = struct {
    expression: resolved.Expression,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *OwnedExpression) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Result = union(enum) { expression: OwnedExpression, diagnostic: Diagnostic };

/// The result borrows neither input nor context. Semantic failures own no arena;
/// their messages are static. Allocation failures are returned separately.
pub fn resolve(allocator: std.mem.Allocator, input: parsed.Expression, context: Context) std.mem.Allocator.Error!Result {
    if (context.field_index) |index| {
        if (index >= context.table.columns.len) return .{ .diagnostic = .{
            .category = .invalid_context,
            .span = input.span,
            .message = "field index is outside the context table",
        } };
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var worker: Worker = .{ .allocator = arena.allocator(), .context = context };
    const expression = worker.expression(input, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SemanticFailure => {
            arena.deinit();
            return .{ .diagnostic = worker.diagnostic.? };
        },
    };
    return .{ .expression = .{ .expression = expression, .arena = arena } };
}

const Worker = struct {
    pub const Error = std.mem.Allocator.Error || error{SemanticFailure};
    allocator: std.mem.Allocator,
    context: Context,
    diagnostic: ?Diagnostic = null,

    pub fn fail(self: *Worker, category: Category, span: parsed.Span, message: []const u8) Error {
        self.diagnostic = .{ .category = category, .span = span, .message = message };
        return error.SemanticFailure;
    }

    fn child(self: *Worker, input: *const parsed.Expression, depth: usize) Error!*const resolved.Expression {
        const value = try self.expression(input.*, depth);
        const output = try self.allocator.create(resolved.Expression);
        output.* = value;
        return output;
    }

    fn reference(self: *Worker, column: resolved.Column) Error!model.Reference {
        return .{ .sql_name = try self.allocator.dupe(u8, column.sql_name) };
    }

    fn expression(self: *Worker, input: parsed.Expression, depth: usize) Error!resolved.Expression {
        if (depth > max_depth) return self.fail(.excessive_depth, input.span, "Expression structural depth exceeds maximum of 256");
        var output: resolved.Expression = .{ .kind = .null_value, .span = input.span };
        switch (input.kind) {
            .integer => |token| {
                try self.numericSpelling(token, false);
                output.kind = .{ .integer = try literals.integer(self, token) };
                output.type_info = .{ .type = .integer };
            },
            .real => |token| {
                try self.numericSpelling(token, true);
                output.kind = .{ .real = try literals.real(self, token) };
                output.type_info = .{ .type = .real };
            },
            .text => |token| {
                output.kind = .{ .text = try literals.string(self, token) };
                output.type_info = .{ .type = .text };
            },
            .boolean => |token| {
                output.kind = .{ .boolean = try literals.boolean(self, token) };
                output.type_info = .{ .type = .boolean };
            },
            .null_value => |token| try literals.nullValue(self, token),
            .raw_sql => |token| output.kind = .{ .raw_sql = try literals.rawSql(self, token) },
            .current_value => |token| {
                if (!std.mem.eql(u8, token.text, "_")) return self.fail(.invalid_identifier, token.span, "current-value reference must be '_'");
                const index = self.context.field_index orelse return self.fail(.invalid_reference_scope, token.span, "'_' is only allowed in field scope");
                const column = self.context.table.columns[index];
                output.kind = .{ .current_value = try self.reference(column) };
                output.type_info = .{ .type = column.type, .nullable = column.nullable };
            },
            .identifier => |token| {
                if (self.context.field_index != null) return self.fail(.invalid_reference_scope, token.span, "named references are only allowed in table scope; use '_' in field scope");
                if (!identifier(token.text) or std.mem.eql(u8, token.text, "_")) return self.fail(.invalid_identifier, token.span, "invalid DSL field identifier");
                for (self.context.table.columns) |column| {
                    if (!std.mem.eql(u8, column.dsl_name, token.text)) continue;
                    output.kind = .{ .identifier = try self.reference(column) };
                    output.type_info = .{ .type = column.type, .nullable = column.nullable };
                    return output;
                }
                return self.fail(.unknown_reference, token.span, "unknown DSL field name");
            },
            .grouping => |inner| {
                const value = try self.child(inner, depth + 1);
                output.kind = .{ .grouping = value };
                output.type_info = value.type_info;
            },
            .unary => |unary| {
                const operand = try self.child(unary.operand, depth + 1);
                output.kind = .{ .unary = .{ .operator = unary.operator, .operand = operand } };
                output.type_info = .{ .type = .boolean, .nullable = maybeNullable(operand) };
            },
            .binary => |binary| {
                const left = try self.child(binary.left, depth + 1);
                const right = try self.child(binary.right, depth + 1);
                output.kind = .{ .binary = .{ .operator = binary.operator, .left = left, .right = right } };
                output.type_info = .{ .type = .boolean, .nullable = maybeNullable(left) or maybeNullable(right) };
            },
        }
        return output;
    }

    // Reject malformed manually constructed numeric tokens before conversion.
    // Valid syntax is the tokenizer's decimal subset, not parseFloat's exponents.
    fn numericSpelling(self: *Worker, token: parsed.Token, real: bool) Error!void {
        const text = token.text;
        var i: usize = if (text.len > 0 and text[0] == '-') 1 else 0;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (i == start) return self.fail(.invalid_literal, token.span, "expected decimal digits");
        if (real) {
            if (i == text.len or text[i] != '.') return self.fail(.invalid_literal, token.span, "real literal requires a decimal fraction");
            i += 1;
            const fraction = i;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
            if (i == fraction) return self.fail(.invalid_literal, token.span, "real literal requires fractional digits");
        }
        if (i != text.len) return self.fail(.invalid_literal, token.span, "invalid decimal literal spelling");
    }
};

fn maybeNullable(expression: *const resolved.Expression) bool {
    return if (expression.type_info) |info| info.nullable else true;
}

fn identifier(text: []const u8) bool {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

test {
    _ = @import("expression_resolver_test.zig");
}
