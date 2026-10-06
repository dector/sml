//! Owned expression resolution with strict logical operand type validation.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");
const model = @import("model/resolved_expression.zig");
const literals = @import("literal_decoder.zig");
const datetime = @import("datetime.zig");

pub const Category = enum {
    invalid_context,
    invalid_reference_scope,
    unknown_reference,
    invalid_literal,
    invalid_identifier,
    unsupported_multiline,
    excessive_depth,
    incompatible_operands,
    invalid_check_type,
    unsupported_null_comparison,
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
pub const IntoResult = union(enum) { expression: resolved.Expression, diagnostic: Diagnostic };

/// Allocate directly into a caller-owned arena. All expression strings are copied.
/// The caller reclaims allocations on either success or diagnostic.
pub fn resolveInto(allocator: std.mem.Allocator, input: parsed.Expression, context: Context) std.mem.Allocator.Error!IntoResult {
    if (context.field_index) |index| {
        if (index >= context.table.columns.len) return .{ .diagnostic = .{
            .category = .invalid_context,
            .span = input.span,
            .message = "field index is outside the context table",
        } };
    }
    var worker: Worker = .{ .allocator = allocator, .context = context };
    const expression = worker.expression(input, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SemanticFailure => return .{ .diagnostic = worker.diagnostic.? },
    };
    return .{ .expression = expression };
}

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
    const result = try resolveInto(arena.allocator(), input, context);
    switch (result) {
        .diagnostic => |diagnostic| {
            arena.deinit();
            return .{ .diagnostic = diagnostic };
        },
        .expression => |expression| return .{ .expression = .{ .expression = expression, .arena = arena } },
    }
}

/// Validate a resolved CHECK root separately; resolve() also permits scalars.
/// Opaque raw SQL is trusted. Nullable Boolean results are valid CHECK roots.
pub fn validateCheckResult(expression: *const resolved.Expression) ?Diagnostic {
    var root = expression;
    var depth: usize = 0;
    while (root.kind == .grouping) : (depth += 1) {
        if (depth >= max_depth) return .{ .category = .excessive_depth, .span = expression.span, .message = "Expression structural depth exceeds maximum of 256" };
        root = root.kind.grouping;
    }
    // Directly constructed models cannot turn a scalar literal into a CHECK
    // root merely by attaching Boolean metadata.
    switch (root.kind) {
        .integer, .real, .text, .null_value => {},
        else => {
            if (root.type_info) |info| {
                if (info.type == .boolean) return null;
            } else if (root.kind == .raw_sql) return null;
        },
    }
    return .{ .category = .invalid_check_type, .span = expression.span, .message = "CHECK expression must be Boolean or trusted raw SQL" };
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
                try self.requireBoolean(operand);
                output.kind = .{ .unary = .{ .operator = unary.operator, .operand = operand } };
                output.type_info = .{ .type = .boolean, .nullable = maybeNullable(operand) };
            },
            .binary => |binary| {
                const left = try self.child(binary.left, depth + 1);
                const right = try self.child(binary.right, depth + 1);
                const operator: model.BinaryOperator = switch (binary.operator) {
                    .logical_and, .logical_or => blk: {
                        try self.requireBoolean(left);
                        try self.requireBoolean(right);
                        break :blk if (binary.operator == .logical_and) .logical_and else .logical_or;
                    },
                    else => try self.comparison(left, right, binary.operator, input.span),
                };
                output.kind = .{ .binary = .{ .operator = operator, .left = left, .right = right } };
                output.type_info = .{ .type = .boolean, .nullable = switch (operator) {
                    .is_null, .is_not_null => false,
                    else => maybeNullable(left) or maybeNullable(right),
                } };
            },
        }
        return output;
    }

    fn requireBoolean(self: *Worker, operand: *const resolved.Expression) Error!void {
        if (operand.type_info) |info| {
            if (info.type == .boolean) return;
        } else if (ungroup(operand).kind == .raw_sql) return;
        return self.fail(.incompatible_operands, operand.span, "logical operators require Boolean operands (or trusted raw SQL)");
    }

    fn comparison(self: *Worker, left: *const resolved.Expression, right: *const resolved.Expression, operator: @import("model/parsed_expression.zig").BinaryOperator, span: parsed.Span) Error!model.BinaryOperator {
        if (ungroup(left).kind == .null_value or ungroup(right).kind == .null_value) {
            return switch (operator) {
                .equal => .is_null,
                .not_equal => .is_not_null,
                else => self.fail(.unsupported_null_comparison, span, "ordering comparisons against null are not supported; use == or !="),
            };
        }
        const lowered: model.BinaryOperator = switch (operator) {
            inline else => |op| @field(model.BinaryOperator, @tagName(op)),
        };
        const ordering = operator != .equal and operator != .not_equal;
        // Even with an opaque peer, a known Boolean/blob cannot be ordered.
        if (ordering) {
            for ([_]*const resolved.Expression{ left, right }) |operand| {
                if (operand.type_info) |info| {
                    if (info.type == .boolean or info.type == .blob)
                        return self.fail(.incompatible_operands, operand.span, "ordering requires numeric, text/enum, date, or datetime operands; Boolean and blob cannot be ordered");
                }
            }
        }
        const l = if (left.type_info) |info| info.type else return lowered;
        const r = if (right.type_info) |info| info.type else return lowered;
        if ((l == .datetime or l == .date) and r == .text and ungroup(right).kind == .text) {
            try self.calendarLiteral(right, l);
            return lowered;
        }
        if ((r == .datetime or r == .date) and l == .text and ungroup(left).kind == .text) {
            try self.calendarLiteral(left, r);
            return lowered;
        }
        if (l == r or (numeric(l) and numeric(r)) or (textual(l) and textual(r))) return lowered;
        return self.fail(.incompatible_operands, span, "comparison requires matching logical families: numeric, text/enum, date, datetime, Boolean equality, or blob-reference equality");
    }

    fn calendarLiteral(self: *Worker, operand: *const resolved.Expression, storage: resolved.StorageType) Error!void {
        if (storage == .date) {
            if (!@import("date.zig").valid(ungroup(operand).kind.text))
                return self.fail(.invalid_literal, operand.span, "date comparison literal must be a valid canonical Gregorian YYYY-MM-DD day");
            return;
        }
        if (!datetime.valid(ungroup(operand).kind.text))
            return self.fail(.invalid_literal, operand.span, "datetime comparison literal must be a valid canonical UTC YYYY-MM-DDTHH:MM:SSZ timestamp");
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

// Resolver-owned trees have already passed the structural depth guard.
fn ungroup(expression: *const resolved.Expression) *const resolved.Expression {
    var node = expression;
    while (node.kind == .grouping) node = node.kind.grouping;
    return node;
}

fn numeric(kind: resolved.StorageType) bool {
    return kind == .integer or kind == .real;
}

fn textual(kind: resolved.StorageType) bool {
    return kind == .text or kind == .enumeration;
}

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
