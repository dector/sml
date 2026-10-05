//! Literal and reference expression parsing. Token text borrows source, which must
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

/// Parses exactly one single-line expression, allowing surrounding blank lines
/// and ordinary comments, but never documentation or a second expression.
/// No partial result escapes on syntax errors or allocation failure.
/// Leaves currently require no allocations; the arena owns future trees.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var lexer = tokenizer.Tokenizer.init(source);
    var p: Parser = .{ .lexer = &lexer };
    const expression = p.run() catch {
        arena.deinit();
        return .{ .diagnostic = p.diagnostic.? };
    };
    return .{ .expression = .{ .expression = expression, .arena = arena } };
}

/// Reusable stream parser. Supply `current` from `lexer.next()`; the lexer must
/// already be positioned after that token. parseExpression consumes one leaf
/// and leaves the next token in `current`, including newline or closing brace.
/// It does not skip trivia or validate the enclosing construct's terminator.
/// All spans remain offsets into the original lexer source.
pub const Parser = struct {
    lexer: *tokenizer.Tokenizer,
    current: tokenizer.Token = undefined,
    diagnostic: ?parsed.Diagnostic = null,

    pub const Error = error{Syntax};

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
            .l_paren, .r_paren => return self.fail(value.span, "Parenthesized expressions are not supported"),
            .bang, .equal, .question => return self.fail(value.span, "Operators are not supported"),
            .doc => return self.fail(value.span, "Documentation is not allowed in expressions"),
            else => return self.fail(value.span, "Expected a literal or reference expression"),
        };
        try self.advance();
        return .{ .kind = kind, .span = value.span };
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
        "Author.name",     "in-progress",     "a-1",        "_x.y",            "_.value",
        "field other",     "field\nother",    "_ _",        "field -- end\n_", "--- docs\nfield",
        "field\n--- docs", "_ --- inline",    "(field)",    "!_",              "field = other",
        "_?",              "field and other", "field str?", "::now",           "#unique",
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
        "1e3",         "foo.bar",         "in-progress", "(1)",             "!true",
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

test "diagnostics retain original source offsets" {
    const result = try parse(std.testing.allocator, "-- heading\n  1  foo");
    try std.testing.expectEqualDeep(parsed.Span{ .start = 16, .end = 19 }, result.diagnostic.span);
    const incomplete = try parse(std.testing.allocator, "  'bad");
    try std.testing.expectEqualDeep(parsed.Span{ .start = 2, .end = 6 }, incomplete.diagnostic.span);
}

test "stream parsing preserves next token and original spans" {
    inline for (.{ "001", "field", "_" }) |leaf| {
        for ([_][]const u8{ "prefix " ++ leaf ++ "\nnext", "prefix " ++ leaf ++ "}" }) |source| {
            var lexer = tokenizer.Tokenizer.init(source);
            _ = lexer.next(); // An enclosing parser already consumed the prefix.
            var p: Parser = .{ .lexer = &lexer, .current = lexer.next().token };
            const expression = try p.parseExpression();
            try std.testing.expectEqualDeep(parsed.Span{ .start = 7, .end = 7 + leaf.len }, expression.span);
            try std.testing.expect(p.current.kind == .newline or p.current.kind == .r_brace);
            try std.testing.expectEqual(@as(usize, 7 + leaf.len), p.current.span.start);
        }
    }
}

fn allocationSuccess(allocator: std.mem.Allocator) !void {
    for ([_][]const u8{ "#'borrowed'# -- end", "field -- end", "_ -- end" }) |source| {
        var result = try parse(allocator, source);
        try std.testing.expect(result == .expression);
        defer result.expression.deinit();
    }
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const result = try parse(allocator, "1 unsupported");
    try std.testing.expect(result == .diagnostic);
}

test "allocation failure checks cover successful and rejected input" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationSuccess, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
    // Leaf parsing must also work when the backing allocator cannot allocate.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try allocationSuccess(failing.allocator());
    try allocationFailure(failing.allocator());
}
