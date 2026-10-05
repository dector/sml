//! Literal, reference, and parenthesized expression parsing. Token text borrows source, which must
//! outlive the result. Numeric conversion and literal decoding belong to resolution.
const std = @import("std");
const parsed = @import("model/parsed.zig");
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
/// Leaves borrow source text; grouping children belong to the result's arena.
/// Recursive nesting is limited to max_nesting (also for future operators).
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

/// Maximum recursive expression nesting, shared by grouping and future operators.
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

    pub fn parseExpression(self: *Parser) Error!parsed.Expression {
        // Keep this at the recursive entry point when adding unary/binary parsing.
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
            .r_paren => return self.fail(value.span, "Expected an expression before ')'"),
            .bang, .equal, .question => return self.fail(value.span, "Operators are not supported"),
            .doc => return self.fail(value.span, "Documentation is not allowed in expressions"),
            else => return self.fail(value.span, "Expected a literal or reference expression"),
        };
        try self.advance();
        return .{ .kind = kind, .span = value.span };
    }

    fn grouping(self: *Parser) Error!parsed.Expression {
        const start = self.current.span.start;
        try self.advance();
        try self.trivia();
        if (self.current.kind == .r_paren)
            return self.fail(self.current.span, "Empty parenthesized expression");
        if (self.current.kind == .eof)
            return self.fail(self.current.span, "Unclosed parenthesized expression; expected ')'");
        const expression = try self.parseExpression();
        try self.trivia();
        if (self.current.kind != .r_paren)
            return self.fail(self.current.span, "Expected ')' after parenthesized expression");
        const end = self.current.span.end;
        try self.advance();
        const child = try self.allocator.create(parsed.Expression);
        child.* = expression;
        return .{ .kind = .{ .grouping = child }, .span = .{ .start = start, .end = end } };
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
        "field\n--- docs", "_ --- inline",    "(field other)", "!_",              "field = other",
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
        "1e3",         "foo.bar",         "in-progress", "(1 2)",           "!true",
        "1 = 2",       "1 + 2",           "1 < 2",       "true and false",  "::now",
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
        "()",               "( -- empty\n)", "(( ))",           "(",               "( -- end",      "(1",      "((1)",
        "(1 -- end\n",      "(1 2)",         "(1\n2)",          "(1) 2",           "(1)\n(2)",      "(1))",    ")",
        "1\n(2)",           "(--- docs\n1)", "(\n--- docs\n1)", "(1\n--- docs\n)", "(1)\n--- docs", "(!true)", "(1 = 2)",
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
    inline for (.{ "001", "field", "_", "((001))", "(\n  field\n)" }) |leaf| {
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

fn allocationSuccess(allocator: std.mem.Allocator) !void {
    try allocationLeaves(allocator);
    for ([_][]const u8{ "((001))", "(\n  ( -- comment\n #'borrowed'#)\n)", &nestedSource(max_nesting, "_") }) |source| {
        var result = try parse(allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
    }
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    for ([_][]const u8{ "1 unsupported", "((1)) unsupported", "(((1))", "((1) --- bad", "((1) 'unterminated" }) |source| {
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
}
