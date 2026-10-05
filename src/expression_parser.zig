//! Literal, reference, grouping, unary logical-not, and comparison expression parsing. Token text borrows source, which must
//! outlive the result. Numeric conversion and literal decoding belong to resolution.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const BinaryOperator = @import("model/parsed_expression.zig").BinaryOperator;
const tokenizer = @import("tokenizer.zig");

pub const OwnedExpression = struct {
    expression: parsed.Expression,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *OwnedExpression) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    expression: OwnedExpression,
    diagnostic: parsed.Diagnostic,
};

/// Parses exactly one expression, allowing newlines/comments inside parentheses
/// and surrounding blank lines/comments, but never docs or bare continuations.
/// No partial result escapes on syntax errors or allocation failure.
/// Leaves borrow source text; all children belong to the result's arena.
/// Recursive nesting and total structural depth are both limited to max_nesting.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var lexer = tokenizer.Tokenizer.init(source);
    var p: Parser = .{ .lexer = &lexer, .allocator = arena.allocator() };
    const expression = p.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            arena.deinit();
            return .{ .diagnostic = p.diagnostic.? };
        },
    };
    return .{ .expression = .{ .expression = expression, .arena = arena } };
}

/// Maximum recursive nesting and structural AST depth (edges to the deepest leaf).
/// Grouping, unary, and binary nodes all consume the same structural budget.
pub const max_nesting = 256;

/// Reusable stream parser. Supply `current` from `lexer.next()`; the lexer must
/// already be positioned after that token. Supply an arena allocator for children.
/// parseExpression consumes one expression and leaves the next token in `current`,
/// including newline or closing brace. It skips trivia only inside parentheses
/// and does not validate the enclosing construct's terminator.
/// All spans remain offsets into the original lexer source.
pub const Parser = struct {
    lexer: *tokenizer.Tokenizer,
    allocator: std.mem.Allocator,
    current: tokenizer.Token = undefined,
    diagnostic: ?parsed.Diagnostic = null,
    depth: usize = 0,
    paren_depth: usize = 0,

    pub const Error = error{Syntax} || std.mem.Allocator.Error;

    fn fail(self: *Parser, span: parsed.Span, message: []const u8) Error {
        self.diagnostic = .{ .span = span, .message = message };
        return error.Syntax;
    }

    fn advance(self: *Parser) Error!void {
        switch (self.lexer.next()) {
            .token => |value| self.current = value,
            .diagnostic => |value| return self.fail(value.span, value.message),
        }
    }

    const Node = struct { expression: parsed.Expression, height: usize = 0 };

    pub fn parseExpression(self: *Parser) Error!parsed.Expression {
        return (try self.comparison()).expression;
    }

    fn structuralDepth(self: *Parser, height: usize, span: parsed.Span) Error!void {
        if (height > max_nesting)
            return self.fail(span, "Expression structural depth exceeds maximum of 256");
    }

    // One precedence level; mixed comparison chains associate left.
    fn comparison(self: *Parser) Error!Node {
        var left = try self.unary();
        while (true) {
            if (self.paren_depth > 0) try self.trivia();
            const operator: BinaryOperator = switch (self.current.kind) {
                .equal_equal => .equal,
                .not_equal => .not_equal,
                .less_than => .less_than,
                .less_than_or_equal => .less_than_or_equal,
                .greater_than => .greater_than,
                .greater_than_or_equal => .greater_than_or_equal,
                else => return left,
            };
            const operator_span = self.current.span;
            try self.advance();
            if (self.paren_depth > 0) try self.trivia();
            const right = try self.unary();
            const height = @max(left.height, right.height) + 1;
            try self.structuralDepth(height, operator_span);
            const lhs = try self.allocator.create(parsed.Expression);
            lhs.* = left.expression;
            const rhs = try self.allocator.create(parsed.Expression);
            rhs.* = right.expression;
            left = .{ .expression = .{
                .kind = .{ .binary = .{ .operator = operator, .operator_span = operator_span, .left = lhs, .right = rhs } },
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
            }, .height = height };
        }
    }

    fn unary(self: *Parser) Error!Node {
        // All grouping and unary operands recurse through this bounded entry point.
        // The root is depth zero; 256 nested constructs plus their leaf are valid.
        if (self.depth > max_nesting)
            return self.fail(self.current.span, "Expression nesting exceeds maximum of 256");
        self.depth += 1;
        defer self.depth -= 1;
        const value = self.current;
        const token: parsed.Token = .{ .text = value.text, .span = value.span };
        const kind: @FieldType(parsed.Expression, "kind") = switch (value.kind) {
            .integer => .{ .integer = token },
            .real => .{ .real = token },
            .string => .{ .text = token },
            .boolean => .{ .boolean = token },
            .backtick => .{ .raw_sql = token },
            .identifier => if (std.mem.eql(u8, value.text, "null"))
                .{ .null_value = token }
            else if (std.mem.eql(u8, value.text, "_"))
                .{ .current_value = token }
            else
                .{ .identifier = token },
            .l_paren => return self.grouping(),
            .bang => return self.logicalNot(),
            .r_paren => return self.fail(value.span, "Expected an expression before ')'"),
            .equal, .question => return self.fail(value.span, "Operators are not supported"),
            .doc => return self.fail(value.span, "Documentation is not allowed in expressions"),
            else => return self.fail(value.span, "Expected a literal or reference expression"),
        };
        try self.advance();
        return .{ .expression = .{ .kind = kind, .span = value.span } };
    }

    // Unary ! binds to the next unary or primary expression (highest precedence).
    fn logicalNot(self: *Parser) Error!Node {
        const start = self.current.span.start;
        try self.advance();
        if (self.paren_depth > 0) try self.trivia();
        const operand = try self.unary();
        try self.structuralDepth(operand.height + 1, .{ .start = start, .end = start + 1 });
        const child = try self.allocator.create(parsed.Expression);
        child.* = operand.expression;
        return .{ .expression = .{
            .kind = .{ .unary = .{ .operator = .logical_not, .operand = child } },
            .span = .{ .start = start, .end = child.span.end },
        }, .height = operand.height + 1 };
    }

    fn grouping(self: *Parser) Error!Node {
        self.paren_depth += 1;
        defer self.paren_depth -= 1;
        const start = self.current.span.start;
        try self.advance();
        try self.trivia();
        if (self.current.kind == .r_paren)
            return self.fail(self.current.span, "Empty parenthesized expression");
        if (self.current.kind == .eof)
            return self.fail(self.current.span, "Unclosed parenthesized expression; expected ')'");
        const expression = try self.comparison();
        try self.trivia();
        if (self.current.kind != .r_paren)
            return self.fail(self.current.span, "Expected ')' after parenthesized expression");
        const end = self.current.span.end;
        try self.advance();
        const child = try self.allocator.create(parsed.Expression);
        try self.structuralDepth(expression.height + 1, .{ .start = start, .end = start + 1 });
        child.* = expression.expression;
        return .{ .expression = .{ .kind = .{ .grouping = child }, .span = .{ .start = start, .end = end } }, .height = expression.height + 1 };
    }

    fn trivia(self: *Parser) Error!void {
        while (self.current.kind == .comment or self.current.kind == .newline) try self.advance();
        if (self.current.kind == .doc)
            return self.fail(self.current.span, "Documentation is not allowed in expressions");
    }

    fn run(self: *Parser) Error!parsed.Expression {
        try self.advance();
        try self.trivia();
        const expression = try self.parseExpression();
        try self.trivia();
        if (self.current.kind != .eof)
            return self.fail(self.current.span, "Expected end of source; trailing tokens and expressions are not supported");
        return expression;
    }
};

test "literal kinds preserve spans, delimiters, spelling and borrowed text" {
    const cases = .{
        .{ "001", .integer },
        .{ "-999999999999999999999999999999999999999", .integer },
        .{ "-001.250", .real },
        .{ "'it''s \\n'", .text },
        .{ "##'a'#b'##", .text },
        .{ "true", .boolean },
        .{ "false", .boolean },
        .{ "null", .null_value },
        .{ "`price > 0`", .raw_sql },
        .{ "#`a`b`#", .raw_sql },
    };
    inline for (cases) |case| {
        const source = "-- leading\r\n\n  " ++ case[0] ++ " -- trailing\n\n-- end";
        var result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
        const expression = result.expression.expression;
        try std.testing.expect(expression.kind == case[1]);
        const token = @field(expression.kind, @tagName(case[1]));
        const start = "-- leading\r\n\n  ".len;
        try std.testing.expectEqualDeep(parsed.Span{ .start = start, .end = start + case[0].len }, expression.span);
        try std.testing.expectEqualDeep(expression.span, token.span);
        try std.testing.expectEqualStrings(case[0], token.text);
        try std.testing.expect(token.text.ptr == source[start..].ptr);
    }
}

test "references and contextual words preserve exact spans and borrowed names" {
    const cases = .{
        .{ "field", .identifier },
        .{ "startsAt", .identifier },
        .{ "Author", .identifier },
        .{ "_field2", .identifier },
        .{ "__", .identifier },
        .{ "str", .identifier },
        .{ "unique", .identifier },
        .{ "now", .identifier },
        .{ "and", .identifier },
        .{ "or", .identifier },
        .{ "trueValue", .identifier },
        .{ "false_", .identifier },
        .{ "null2", .identifier },
        .{ "True", .identifier },
        .{ "Null", .identifier },
        .{ "_", .current_value },
    };
    inline for (cases) |case| {
        const source = "-- heading\r\n  " ++ case[0] ++ " -- end\n";
        var result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
        const expression = result.expression.expression;
        try std.testing.expect(expression.kind == case[1]);
        const token = @field(expression.kind, @tagName(case[1]));
        const start = "-- heading\r\n  ".len;
        try std.testing.expectEqualDeep(parsed.Span{ .start = start, .end = start + case[0].len }, expression.span);
        try std.testing.expectEqualDeep(expression.span, token.span);
        try std.testing.expectEqualStrings(case[0], token.text);
        try std.testing.expect(token.text.ptr == source[start..].ptr);
    }
}

test "current value is expression syntax, not a declaration name or default" {
    const schema_parser = @import("parser.zig");
    for ([_][]const u8{ "_ {}", "T {\n  _ str\n}", "T {\n  value str = _\n}" }) |source| {
        const result = try schema_parser.parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
    }
}

test "reference grammar rejects dotted and enum names, trailing tokens and docs" {
    const cases = [_][]const u8{
        "Author.name",     "in-progress",     "a-1",           "_x.y",            "_.value",
        "field other",     "field\nother",    "_ _",           "field -- end\n_", "--- docs\nfield",
        "field\n--- docs", "_ --- inline",    "(field other)", "!",               "field = other",
        "_?",              "field and other", "field str?",    "::now",           "#unique",
        "field {}",
    };
    for (cases) |source| {
        const result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(result.diagnostic.message.len > 0);
        try std.testing.expect(result.diagnostic.span.start <= result.diagnostic.span.end);
        try std.testing.expect(result.diagnostic.span.end <= source.len);
    }
}

test "reject empty, incomplete, unsupported and trailing syntax" {
    const cases = [_][]const u8{
        "",            " \n-- comment",   "--- docs\n1", "1\n--- docs",     "1 --- inline",
        "'unfinished", "#'unfinished'##", "`unfinished", "'a\nb'",          "1.",
        "1e3",         "foo.bar",         "in-progress", "(1 2)",           "!\ntrue",
        "1 = 2",       "1 + 2",           "1 <",         "true and false",  "::now",
        "#name",       "1 2",             "1\n2",        "1 -- comment\n2", "1\n+ 2",
        "1 }",         "null?",
    };
    for (cases) |source| {
        const result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(result.diagnostic.message.len > 0);
        try std.testing.expect(result.diagnostic.span.start <= result.diagnostic.span.end);
        try std.testing.expect(result.diagnostic.span.end <= source.len);
    }
}

test "unary logical not owns operands and includes operators in spans" {
    inline for (.{ "true", "false", "null", "field", "_", "001", "-001.250", "'text'", "`sql`", "(field)" }) |leaf| {
        const source = "  ! ! " ++ leaf ++ " -- end\n";
        var result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
        const outer = result.expression.expression;
        const inner = outer.kind.unary.operand;
        const operand = inner.kind.unary.operand;
        try std.testing.expect(outer.kind.unary.operator == .logical_not);
        try std.testing.expect(inner.kind.unary.operator == .logical_not);
        try std.testing.expectEqualDeep(parsed.Span{ .start = 2, .end = 6 + leaf.len }, outer.span);
        try std.testing.expectEqualDeep(parsed.Span{ .start = 4, .end = 6 + leaf.len }, inner.span);
        try std.testing.expectEqualDeep(parsed.Span{ .start = 6, .end = 6 + leaf.len }, operand.span);
        try std.testing.expectEqualStrings(leaf, source[operand.span.start..operand.span.end]);
    }
    var result = try parse(std.testing.allocator, "!(!\r\n -- comment\n !\n field\n)");
    try std.testing.expect(result == .expression);
    defer result.expression.deinit();
    const group = result.expression.expression.kind.unary.operand;
    const unary = group.kind.grouping;
    try std.testing.expectEqualStrings("field", unary.kind.unary.operand.kind.unary.operand.kind.identifier.text);
}

test "unary rejects missing operands bare breaks arithmetic and docs" {
    for ([_][]const u8{
        "!",                  "!!",        "! ",     "(!",    "(!!",       "(!)",       "!\ntrue",            "!!\ntrue",
        "! -- comment\ntrue", "!\n(true)", "!(!)",   "(!\n)", "(! -- end", "! --- doc", "(!\n--- doc\ntrue)", "!true false",
        "!true = false",      "+1",        "-field", "-(1)",  "!+1",       "!-(1)",     "- 1",                "!true + 1",
    }) |source| {
        const result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(result.diagnostic.message.len > 0);
        try std.testing.expect(result.diagnostic.span.start <= result.diagnostic.span.end);
        try std.testing.expect(result.diagnostic.span.end <= source.len);
    }
    for ([_][]const u8{ "!", "!!", "(!", "(! -- end\n" }) |source| {
        const result = try parse(std.testing.allocator, source);
        try std.testing.expectEqualDeep(parsed.Span{ .start = source.len, .end = source.len }, result.diagnostic.span);
    }
    const schema_parser = @import("parser.zig");
    for ([_][]const u8{ "T {\n  value bool = !true\n}", "T {\n  value bool = !!false\n}", "T {\n  value int = !1\n}" }) |source| {
        const result = try schema_parser.parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
    }
}

test "unary chains share the grouping depth bound" {
    const source = &unarySource(max_nesting, "_");
    var result = try parse(std.testing.allocator, source);
    try std.testing.expect(result == .expression);
    defer result.expression.deinit();
    var node: *const parsed.Expression = &result.expression.expression;
    for (0..max_nesting) |_| node = node.kind.unary.operand;
    try std.testing.expectEqualStrings("_", node.kind.current_value.text);
    var mixed = try parse(std.testing.allocator, &nestedSource(max_nesting / 2, &unarySource(max_nesting / 2, "true")));
    try std.testing.expect(mixed == .expression);
    defer mixed.expression.deinit();
    for ([_][]const u8{
        &unarySource(max_nesting + 1, "true"),
        &unarySource(10000, "true"),
        &nestedSource(max_nesting / 2, &unarySource(max_nesting / 2 + 1, "true")),
    }) |deep| {
        const rejected = try parse(std.testing.allocator, deep);
        try std.testing.expect(rejected == .diagnostic);
        try std.testing.expectEqualStrings("Expression nesting exceeds maximum of 256", rejected.diagnostic.message);
    }
}

test "groups own children and preserve exact grouping and leaf spans" {
    inline for (.{ "001", "-001.250", "'it''s'", "#'raw'#", "true", "null", "field", "_", "#`sql`#" }) |leaf| {
        const prefix = "-- heading\r\n  ( -- outer\r\n     (\n-- inner\n ";
        const source = prefix ++ leaf ++ " -- leaf\n  )\r\n) -- end\n";
        var result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
        const outer = result.expression.expression;
        const inner = outer.kind.grouping;
        const value = inner.kind.grouping;
        try std.testing.expectEqualStrings("( -- outer\r\n     (\n-- inner\n " ++ leaf ++ " -- leaf\n  )\r\n)", source[outer.span.start..outer.span.end]);
        try std.testing.expectEqualStrings("(\n-- inner\n " ++ leaf ++ " -- leaf\n  )", source[inner.span.start..inner.span.end]);
        try std.testing.expectEqualDeep(parsed.Span{ .start = prefix.len, .end = prefix.len + leaf.len }, value.span);
        switch (value.kind) {
            .integer, .real, .text, .boolean, .null_value, .identifier, .current_value, .raw_sql => |token| {
                try std.testing.expectEqualStrings(leaf, token.text);
                try std.testing.expectEqualDeep(value.span, token.span);
                try std.testing.expect(token.text.ptr == source[prefix.len..].ptr);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "grouping rejects empty unclosed docs operators and bare continuations" {
    for ([_][]const u8{
        "()",               "( -- empty\n)", "(( ))",           "(",               "( -- end",      "(1",   "((1)",
        "(1 -- end\n",      "(1 2)",         "(1\n2)",          "(1) 2",           "(1)\n(2)",      "(1))", ")",
        "1\n(2)",           "(--- docs\n1)", "(\n--- docs\n1)", "(1\n--- docs\n)", "(1)\n--- docs", "(!)",  "(1 = 2)",
        "(true and false)", "(1 + 2)",       "(field.name)",
    }) |source| {
        const result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(result.diagnostic.message.len > 0);
        try std.testing.expect(result.diagnostic.span.start <= result.diagnostic.span.end);
        try std.testing.expect(result.diagnostic.span.end <= source.len);
    }
    const empty = try parse(std.testing.allocator, "  ()");
    try std.testing.expectEqualDeep(parsed.Span{ .start = 3, .end = 4 }, empty.diagnostic.span);
    const unclosed = try parse(std.testing.allocator, " (1\n");
    try std.testing.expectEqualDeep(parsed.Span{ .start = 4, .end = 4 }, unclosed.diagnostic.span);
    // Standalone expression grouping must not extend schema defaults.
    const schema_parser = @import("parser.zig");
    const schema = try schema_parser.parse(std.testing.allocator, "T {\n  value int = (1)\n}");
    try std.testing.expect(schema == .diagnostic);
}

fn unarySource(comptime count: usize, comptime leaf: []const u8) [count + leaf.len]u8 {
    var source: [count + leaf.len]u8 = undefined;
    @memset(source[0..count], '!');
    @memcpy(source[count..], leaf);
    return source;
}

fn nestedSource(comptime count: usize, comptime leaf: []const u8) [count * 2 + leaf.len]u8 {
    var source: [count * 2 + leaf.len]u8 = undefined;
    @memset(source[0..count], '(');
    @memcpy(source[count..][0..leaf.len], leaf);
    @memset(source[count + leaf.len ..], ')');
    return source;
}

test "public parsing limits nesting before stack overflow" {
    const source = nestedSource(max_nesting, "001");
    var result = try parse(std.testing.allocator, &source);
    try std.testing.expect(result == .expression);
    defer result.expression.deinit();
    var node: *const parsed.Expression = &result.expression.expression;
    for (0..max_nesting) |_| node = node.kind.grouping;
    try std.testing.expectEqualStrings("001", node.kind.integer.text);
    for ([_][]const u8{
        &nestedSource(max_nesting + 1, "1"),
        &nestedSource(10000, "1"),
    }) |deep| {
        const rejected = try parse(std.testing.allocator, deep);
        try std.testing.expect(rejected == .diagnostic);
        try std.testing.expectEqualStrings("Expression nesting exceeds maximum of 256", rejected.diagnostic.message);
    }
}

test "diagnostics retain original source offsets" {
    const result = try parse(std.testing.allocator, "-- heading\n  1  foo");
    try std.testing.expectEqualDeep(parsed.Span{ .start = 16, .end = 19 }, result.diagnostic.span);
    const incomplete = try parse(std.testing.allocator, "  'bad");
    try std.testing.expectEqualDeep(parsed.Span{ .start = 2, .end = 6 }, incomplete.diagnostic.span);
}

test "stream parsing preserves next token and original spans" {
    inline for (.{ "001", "field", "_", "((001))", "(\n  field\n)", "!!_", "!(field)", "!a >= b", "(a\n<=\nb)", "(!\n true)" }) |leaf| {
        for ([_][]const u8{ "prefix " ++ leaf ++ "\nnext", "prefix " ++ leaf ++ "}" }) |source| {
            var lexer = tokenizer.Tokenizer.init(source);
            _ = lexer.next(); // An enclosing parser already consumed the prefix.
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var p: Parser = .{ .lexer = &lexer, .allocator = arena.allocator(), .current = lexer.next().token };
            const expression = try p.parseExpression();
            try std.testing.expectEqualDeep(parsed.Span{ .start = 7, .end = 7 + leaf.len }, expression.span);
            try std.testing.expect(p.current.kind == .newline or p.current.kind == .r_brace);
            try std.testing.expectEqual(@as(usize, 7 + leaf.len), p.current.span.start);
        }
    }
}

fn allocationLeaves(allocator: std.mem.Allocator) !void {
    for ([_][]const u8{ "#'borrowed'# -- end", "field -- end", "_ -- end" }) |source| {
        var result = try parse(allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
    }
}

fn allocationSuccess(backing: std.mem.Allocator) !void {
    // Arena growth must allocate rather than depend on in-place backing growth.
    var no_resize = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    const allocator = no_resize.allocator();
    try allocationLeaves(allocator);
    for ([_][]const u8{ "((001))", "(\n  ( -- comment\n #'borrowed'#)\n)", &nestedSource(max_nesting, "_"), "!!true", "!(!\n -- operand\n field)", &unarySource(max_nesting, "_"), "!a==b!=c<d<=e>f>=g", "(a\n<=\n!b)", &comparisonSource(max_nesting) }) |source| {
        var result = try parse(allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
    }
}

fn allocationFailure(backing: std.mem.Allocator) !void {
    var no_resize = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    const allocator = no_resize.allocator();
    for ([_][]const u8{ "1 unsupported", "((1)) unsupported", "(((1))", "((1) --- bad", "((1) 'unterminated", "!!true unsupported", "(!!true", "(!true !", "!", "!!", "! 'unterminated", "a==", "a!=b<", "(a<=b", "a>=b unsupported", "a==b 'unterminated", &comparisonSource(max_nesting + 1), &nestedSource(1, &comparisonSource(max_nesting)) }) |source| {
        const result = try parse(allocator, source);
        try std.testing.expect(result == .diagnostic);
    }
}

test "allocation failure checks cover successful and rejected input" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationSuccess, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
    // Leaf parsing must also work when the backing allocator cannot allocate.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try allocationLeaves(failing.allocator());
    const result = try parse(failing.allocator(), "1 unsupported");
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectError(error.OutOfMemory, parse(failing.allocator(), "((1))"));
    try std.testing.expectError(error.OutOfMemory, parse(failing.allocator(), "!true"));
    try std.testing.expectError(error.OutOfMemory, parse(failing.allocator(), "a==b"));
}

fn comparisonSource(comptime count: usize) [1 + count * 3]u8 {
    var source: [1 + count * 3]u8 = undefined;
    source[0] = 'a';
    for (0..count) |i| @memcpy(source[1 + i * 3 ..][0..3], "==a");
    return source;
}

test "comparisons preserve full operator tokens and arena children" {
    inline for (.{
        .{ "==", .equal },       .{ "!=", .not_equal },
        .{ "<", .less_than },    .{ "<=", .less_than_or_equal },
        .{ ">", .greater_than }, .{ ">=", .greater_than_or_equal },
    }) |case| {
        const source = "  !a " ++ case[0] ++ " !b ";
        var result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
        const node = result.expression.expression;
        const binary = node.kind.binary;
        try std.testing.expectEqual(@as(BinaryOperator, case[1]), binary.operator);
        try std.testing.expectEqualDeep(parsed.Span{ .start = 5, .end = 5 + case[0].len }, binary.operator_span);
        try std.testing.expectEqualStrings(case[0], source[binary.operator_span.start..binary.operator_span.end]);
        try std.testing.expectEqualDeep(parsed.Span{ .start = 2, .end = source.len - 1 }, node.span);
        try std.testing.expectEqualStrings("a", binary.left.kind.unary.operand.kind.identifier.text);
        try std.testing.expectEqualStrings("b", binary.right.kind.unary.operand.kind.identifier.text);
        try std.testing.expect(binary.left != binary.right);
    }
}

test "comparison chains associate left including mixed operators" {
    var result = try parse(std.testing.allocator, "a < b == c >= d");
    try std.testing.expect(result == .expression);
    defer result.expression.deinit();
    const outer = result.expression.expression.kind.binary;
    try std.testing.expectEqual(BinaryOperator.greater_than_or_equal, outer.operator);
    try std.testing.expectEqualStrings("d", outer.right.kind.identifier.text);
    const middle = outer.left.kind.binary;
    try std.testing.expectEqual(BinaryOperator.equal, middle.operator);
    try std.testing.expectEqualStrings("c", middle.right.kind.identifier.text);
    const inner = middle.left.kind.binary;
    try std.testing.expectEqual(BinaryOperator.less_than, inner.operator);
    try std.testing.expectEqualStrings("a", inner.left.kind.identifier.text);
    try std.testing.expectEqualStrings("b", inner.right.kind.identifier.text);
    try std.testing.expectEqualDeep(parsed.Span{ .start = 0, .end = 5 }, middle.left.span);
    var grouped = try parse(std.testing.allocator, "!(a\r\n -- comment\n <=\n !b)");
    try std.testing.expect(grouped == .expression);
    defer grouped.expression.deinit();
    try std.testing.expect(grouped.expression.expression.kind.unary.operand.kind.grouping.kind == .binary);
}

test "comparison syntax rejects missing operands bare continuations and arithmetic" {
    for ([_][]const u8{
        "==a",    "a==",    "a!=",               "a<",                "a<=",   "a>",                 "a>=", "a===b", "a<==b",
        "a==\nb", "a\n==b", "a -- comment\n==b", "a== -- comment\nb", "(a==)", "(a==\n--- docs\nb)", "a+b", "a*b",   "a/b",
        "a- b",   "a=b",
    }) |source| {
        const result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(result.diagnostic.message.len > 0);
        try std.testing.expect(result.diagnostic.span.end <= source.len);
    }
    const result = try parse(std.testing.allocator, "a == >= b");
    try std.testing.expectEqualDeep(parsed.Span{ .start = 5, .end = 7 }, result.diagnostic.span);
}

test "structural budget bounds linear chains and combined constructs" {
    var accepted = try parse(std.testing.allocator, &comparisonSource(max_nesting));
    try std.testing.expect(accepted == .expression);
    defer accepted.expression.deinit();
    var node: *const parsed.Expression = &accepted.expression.expression;
    for (0..max_nesting) |_| node = node.kind.binary.left;
    try std.testing.expect(node.kind == .identifier);
    for ([_][]const u8{
        &comparisonSource(max_nesting + 1),
        &comparisonSource(10000),
        &nestedSource(1, &comparisonSource(max_nesting)),
        &unarySource(1, &nestedSource(1, &comparisonSource(max_nesting - 1))),
        &unarySource(max_nesting, "a==b"),
    }) |source| {
        const result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqualStrings("Expression structural depth exceeds maximum of 256", result.diagnostic.message);
    }
}
