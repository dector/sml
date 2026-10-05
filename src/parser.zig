//! Supported-subset recursive descent parser. `.schema` owns arrays and joined
//! documentation through an arena; all other text borrows the input source.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const tokenizer = @import("tokenizer.zig");
const expression_parser = @import("expression_parser.zig");

pub const Result = parsed.Result;
pub const Diagnostic = parsed.Diagnostic;
const Token = tokenizer.Token;
const Kind = tokenizer.Kind;
const Error = std.mem.Allocator.Error || error{Syntax};

/// On diagnostics and allocation failure, no partial schema escapes.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var p: Parser = .{ .allocator = arena.allocator(), .lexer = tokenizer.Tokenizer.init(source) };
    const schema = p.run() catch |err| switch (err) {
        error.Syntax => {
            arena.deinit();
            return .{ .diagnostic = p.diagnostic.? };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .schema = .{ .schema = schema, .arena = arena } };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: tokenizer.Tokenizer,
    current: Token = undefined,
    diagnostic: ?Diagnostic = null,

    fn fail(self: *Parser, span: parsed.Span, message: []const u8) Error {
        self.diagnostic = .{ .span = span, .message = message };
        return error.Syntax;
    }

    fn advance(self: *Parser) Error!void {
        switch (self.lexer.next()) {
            .token => |value| self.current = value,
            .diagnostic => |diagnostic| return self.fail(diagnostic.span, diagnostic.message),
        }
    }

    fn take(self: *Parser, kind: Kind, message: []const u8) Error!Token {
        if (self.current.kind != kind) return self.fail(self.current.span, message);
        const value = self.current;
        try self.advance();
        return value;
    }

    fn token(value: Token) parsed.Token {
        return .{ .text = value.text, .span = value.span };
    }

    fn word(self: *Parser, text: []const u8) bool {
        return self.current.kind == .identifier and std.mem.eql(u8, self.current.text, text);
    }

    fn name(self: *Parser) Error!Token {
        if (self.word("_") or self.word("true") or self.word("false") or self.word("null"))
            return self.fail(self.current.span, "Reserved literal or placeholder cannot be a declaration name");
        return self.take(.identifier, "Expected a declaration name");
    }

    // Every nonempty declaration/directive must end on its own physical line.
    fn lineEnd(self: *Parser) Error!void {
        if (self.current.kind == .comment) try self.advance();
        switch (self.current.kind) {
            .newline => try self.advance(),
            .eof => {},
            .doc => return self.fail(self.current.span, "Documentation must be standalone"),
            else => return self.fail(self.current.span, "Expected end of line; unsupported syntax or mixed body forms"),
        }
    }

    /// Ordinary comments preserve attachment; a blank line breaks it and makes
    /// any pending block unattached. Call only at statement boundaries.
    fn trivia(self: *Parser) Error!?parsed.Documentation {
        var text: std.ArrayList(u8) = .empty;
        var span: ?parsed.Span = null;
        while (true) switch (self.current.kind) {
            .newline => {
                if (span) |s| return self.fail(s, "Unattached documentation before blank line");
                try self.advance();
            },
            .comment => {
                try self.advance();
                try self.lineEnd();
            },
            .doc => {
                const doc = self.current;
                if (span == null) span = doc.span else {
                    span.?.end = doc.span.end;
                    try text.append(self.allocator, '\n');
                }
                var content = doc.text[3..];
                if (content.len > 0 and content[0] == ' ') content = content[1..];
                try text.appendSlice(self.allocator, content);
                try self.advance();
                if (self.current.kind != .newline and self.current.kind != .eof)
                    return self.fail(self.current.span, "Documentation must be standalone");
                try self.lineEnd();
            },
            else => break,
        };
        if (span) |s| return .{ .text = try text.toOwnedSlice(self.allocator), .span = s };
        return null;
    }

    fn noDocs(self: *Parser, docs: ?parsed.Documentation) Error!void {
        if (docs) |d| return self.fail(d.span, "Unattached documentation: expected a declaration, not a directive or closing scope");
    }

    fn run(self: *Parser) Error!parsed.Schema {
        try self.advance();
        var tables: std.ArrayList(parsed.Table) = .empty;
        while (true) {
            const docs = try self.trivia();
            if (self.current.kind == .eof) {
                try self.noDocs(docs);
                break;
            }
            try tables.append(self.allocator, try self.table(docs));
        }
        return .{ .tables = try tables.toOwnedSlice(self.allocator) };
    }

    fn table(self: *Parser, docs: ?parsed.Documentation) Error!parsed.Table {
        const first = try self.name();
        _ = try self.take(.l_brace, "Expected '{' on table declaration line; non-table declarations are unsupported");
        var fields: std.ArrayList(parsed.Field) = .empty;
        var directives: std.ArrayList(parsed.Directive) = .empty;
        if (self.current.kind != .r_brace) {
            try self.lineEnd();
            while (true) {
                const field_docs = try self.trivia();
                if (self.current.kind == .r_brace) {
                    try self.noDocs(field_docs);
                    break;
                }
                if (self.current.kind == .eof) return self.fail(self.current.span, "Expected '}' to close table");
                if (self.current.kind == .hash or self.current.kind == .question) {
                    try self.noDocs(field_docs);
                    try directives.append(self.allocator, try self.directive(false));
                    try self.lineEnd();
                } else try fields.append(self.allocator, try self.field(field_docs));
            }
        }
        const close = try self.take(.r_brace, "Expected '}' to close table");
        try self.lineEnd();
        return .{ .name = token(first), .documentation = docs, .fields = try fields.toOwnedSlice(self.allocator), .directives = try directives.toOwnedSlice(self.allocator), .span = .{ .start = first.span.start, .end = close.span.end } };
    }

    fn field(self: *Parser, docs: ?parsed.Documentation) Error!parsed.Field {
        const first = self.current;
        const primary = first.kind == .bang;
        if (primary) try self.advance();
        const field_name = try self.name();
        const type_name = try self.name();
        var end = type_name.span.end;
        var nullable = false;
        if (self.current.kind == .question) {
            nullable = true;
            end = self.current.span.end;
            try self.advance();
        }
        const type_span: parsed.Span = .{ .start = type_name.span.start, .end = end };
        const is_enum = std.mem.eql(u8, type_name.text, "enum");
        var default: ?parsed.Default = null;
        if (self.current.kind == .l_paren) {
            self.lexer.enum_value_mode = is_enum;
            try self.advance();
            try self.expressionTrivia();
            const value = self.current;
            default = if (is_enum) switch (value.kind) {
                .identifier => if (self.word("null")) .{ .null_value = token(value) } else .{ .enum_text = token(value) },
                .backtick => .{ .enum_text = token(value) },
                else => return self.fail(value.span, "Enum defaults require a bare word, backtick text, or nullable null"),
            } else switch (value.kind) {
                .integer => .{ .integer = token(value) },
                .boolean => .{ .boolean = token(value) },
                .real => .{ .real = token(value) },
                .string => .{ .text = token(value) },
                .backtick => .{ .raw_sql = token(value) },
                .generator => if (std.mem.eql(u8, type_name.text, "datetime")) .{ .generator = token(value) } else return self.fail(value.span, "Generators are supported only for datetime defaults"),
                .identifier => if (self.word("null")) .{ .null_value = token(value) } else return self.fail(value.span, "Unsupported default; expected a literal or raw SQL"),
                else => return self.fail(value.span, "Expected default literal"),
            };
            self.lexer.enum_value_mode = false;
            try self.advance();
            try self.expressionTrivia();
            end = (try self.take(.r_paren, "Expected ')' after default literal; expressions are unsupported")).span.end;
        }
        var directives: std.ArrayList(parsed.Directive) = .empty;
        switch (self.current.kind) {
            .l_brace => {
                try self.advance();
                if (self.current.kind != .r_brace) {
                    try self.lineEnd();
                    while (true) {
                        try self.noDocs(try self.trivia());
                        if (self.current.kind == .r_brace) break;
                        if (self.current.kind == .eof) return self.fail(self.current.span, "Expected '}' to close field body");
                        try directives.append(self.allocator, try self.directive(true));
                        try self.lineEnd();
                    }
                }
                end = (try self.take(.r_brace, "Expected '}' to close field body")).span.end;
                try self.lineEnd();
            },
            .equal => {
                end = self.current.span.end;
                try self.advance();
                try self.lineEnd();
                const indent = first.indent + 2;
                var has_item = false;
                while (true) {
                    // Comments never end the scope, but correctly indented ones
                    // make a comment-only body nonempty.
                    while (self.current.kind == .newline or self.current.kind == .comment) {
                        if (self.current.kind == .comment) {
                            if (self.current.indent == indent) {
                                has_item = true;
                                end = self.current.span.end;
                            }
                            try self.advance();
                            try self.lineEnd();
                        } else try self.advance();
                    }
                    if (self.current.kind == .doc and self.current.indent < indent) break;
                    if (self.current.kind == .doc) {
                        const body_docs = try self.trivia();
                        try self.noDocs(body_docs);
                    }
                    if (self.current.kind == .eof or self.current.kind == .r_brace or self.current.indent < indent) break;
                    if (self.current.indent != indent) return self.fail(self.current.span, "Body items must be indented exactly two spaces beyond the declaration");
                    const directive_value = try self.directive(true);
                    try directives.append(self.allocator, directive_value);
                    end = directive_value.span.end;
                    has_item = true;
                    try self.lineEnd();
                }
                if (!has_item) return self.fail(.{ .start = first.span.start, .end = end }, "Empty indentation body");
            },
            else => try self.lineEnd(),
        }
        return .{ .name = token(field_name), .documentation = docs, .type = .{ .name = token(type_name), .nullable = nullable, .span = type_span }, .primary_key = primary, .default = default, .directives = try directives.toOwnedSlice(self.allocator), .span = .{ .start = first.span.start, .end = end } };
    }

    fn expressionTrivia(self: *Parser) Error!void {
        while (self.current.kind == .newline or self.current.kind == .comment) try self.advance();
    }

    fn check(self: *Parser, start: usize) Error!parsed.Directive {
        var p: expression_parser.Parser = .{ .lexer = &self.lexer, .allocator = self.allocator, .current = self.current };
        const expression = p.parseExpression() catch |err| {
            self.current = p.current;
            self.diagnostic = p.diagnostic;
            return err;
        };
        self.current = p.current;
        if (self.current.kind == .l_brace) return self.fail(self.current.span, "Named check bodies are not supported yet; use #check expr");
        return .{ .kind = .{ .check = expression }, .span = .{ .start = start, .end = expression.span.end } };
    }

    fn directive(self: *Parser, field_scope: bool) Error!parsed.Directive {
        if (self.current.kind == .question) {
            const marker = self.current;
            if (!field_scope) return self.fail(marker.span, "Checks are field-only; table checks are not supported yet");
            try self.advance();
            if (self.current.kind == .question) return self.fail(self.current.span, "Table checks (??) are not supported yet; use ? expr in a field body");
            return self.check(marker.span.start);
        }
        const hash = try self.take(.hash, "Expected supported field directive or ? expression");
        if (self.word("check")) {
            if (!field_scope) return self.fail(self.current.span, "#check is field-only; table checks are not supported yet");
            try self.advance();
            if (self.current.kind == .l_brace) return self.fail(self.current.span, "Named check bodies are not supported yet; use #check expr");
            return self.check(hash.span.start);
        }
        if (self.word("name")) {
            try self.advance();
            const value = try self.take(.backtick, "#name requires a backtick literal");
            return .{ .kind = .{ .name = token(value) }, .span = .{ .start = hash.span.start, .end = value.span.end } };
        }
        if (self.word("of")) {
            if (!field_scope) return self.fail(self.current.span, "#of is field-only");
            self.lexer.enum_value_mode = true;
            try self.advance();
            var values: std.ArrayList(parsed.Token) = .empty;
            while (true) {
                const value = self.current;
                if (value.kind != .backtick and (value.kind != .identifier or self.word("null")))
                    return self.fail(value.span, "#of requires enum words or backtick text; quote null");
                try values.append(self.allocator, token(value));
                try self.advance();
                if (self.current.kind != .comma) break;
                try self.advance();
            }
            self.lexer.enum_value_mode = false;
            const end = values.items[values.items.len - 1].span.end;
            return .{ .kind = .{ .of = try values.toOwnedSlice(self.allocator) }, .span = .{ .start = hash.span.start, .end = end } };
        }
        if (self.word("allow")) {
            if (!field_scope) return self.fail(self.current.span, "#allow reuse is supported only in field bodies");
            try self.advance();
            if (!self.word("reuse")) return self.fail(self.current.span, "Only #allow reuse is supported");
            const end = self.current.span.end;
            try self.advance();
            return .{ .kind = .allow_reuse, .span = .{ .start = hash.span.start, .end = end } };
        }
        return self.fail(self.current.span, "Unsupported directive");
    }
};

fn expectDiagnostic(source: []const u8) !Diagnostic {
    var result = try parse(std.testing.allocator, source);
    switch (result) {
        .schema => |*owned| {
            owned.deinit();
            return error.ExpectedDiagnostic;
        },
        .diagnostic => |diagnostic| return diagnostic,
    }
}

test "parser preserves docs, spans, unresolved types, defaults and duplicate directives" {
    const source =
        "--- Public author.\n" ++
        "-- internal\n" ++
        "---  Extra space.\n" ++
        "Author {\n" ++
        "#name #`people`#\n" ++
        "    --- Identifier.\n" ++
        "    !id Unknown?(\n" ++
        " -001\n" ++
        ") = -- header comment\n" ++
        "      #allow reuse\n" ++
        "      #allow reuse\n" ++
        "    --- Name.\n" ++
        "    name str('it''s -- literal') {\n" ++
        "#name ##`foo`bar`##\n" ++
        "    }\n" ++
        "}\n";
    var result = try parse(std.testing.allocator, source);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const table = result.schema.schema.tables[0];
    try std.testing.expectEqualStrings("Public author.\n Extra space.", table.documentation.?.text);
    try std.testing.expectEqual(@as(usize, 0), table.documentation.?.span.start);
    try std.testing.expectEqualStrings("--- Public author.\n-- internal\n---  Extra space.", source[table.documentation.?.span.start..table.documentation.?.span.end]);
    try std.testing.expectEqualStrings("Author", table.name.text);
    try std.testing.expectEqualStrings("#name #`people`#", source[table.directives[0].span.start..table.directives[0].span.end]);
    const id = table.fields[0];
    try std.testing.expect(id.primary_key);
    try std.testing.expect(id.type.nullable);
    try std.testing.expectEqualStrings("Unknown?", source[id.type.span.start..id.type.span.end]);
    try std.testing.expectEqualStrings("-001", id.default.?.integer.text);
    try std.testing.expectEqualStrings("Identifier.", id.documentation.?.text);
    try std.testing.expectEqual(@as(usize, 2), id.directives.len);
    try std.testing.expect(source[id.span.start] == '!');
    try std.testing.expectEqualStrings("#allow reuse", source[id.span.end - 12 .. id.span.end]);
    const name_field = table.fields[1];
    try std.testing.expectEqualStrings("Name.", name_field.documentation.?.text);
    try std.testing.expectEqualStrings("'it''s -- literal'", name_field.default.?.text.text);
    try std.testing.expectEqualStrings("##`foo`bar`##", name_field.directives[0].kind.name.text);
    try std.testing.expect(source[name_field.span.end - 1] == '}');
    try std.testing.expect(source[table.span.end - 1] == '}');
}

test "parser accepts all modeled literal forms and contextual identifiers" {
    const source =
        "T {\n" ++
        "str str\n" ++
        "unique Unknown\n" ++
        "a int(001)\n" ++
        "b real(-0.50)\n" ++
        "c str(#'raw \\ -- '#)\n" ++
        "d str?(null)\n" ++
        "e int(#`abs(`x`)`#)\n" ++
        "f str('literal \\ path') {}\n" ++
        "}\n" ++
        "Empty {}";
    var result = try parse(std.testing.allocator, source);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const fields = result.schema.schema.tables[0].fields;
    try std.testing.expectEqualStrings("Unknown", fields[1].type.name.text);
    try std.testing.expectEqualStrings("001", fields[2].default.?.integer.text);
    try std.testing.expectEqualStrings("-0.50", fields[3].default.?.real.text);
    try std.testing.expectEqualStrings("#'raw \\ -- '#", fields[4].default.?.text.text);
    try std.testing.expect(fields[5].default.? == .null_value);
    try std.testing.expectEqualStrings("#`abs(`x`)`#", fields[6].default.?.raw_sql.text);
    try std.testing.expectEqual(@as(usize, 0), result.schema.schema.tables[1].fields.len);
}

test "parser comment-only indentation body and blank lines preserve scope" {
    const source = "T {\n    a int =\n\n-- ignored\n      -- TODO\n\n    b int =\n\n      #name `b`\n-- does not dedent\n\n      #allow reuse\n    c int\n}\n";
    var result = try parse(std.testing.allocator, source);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const fields = result.schema.schema.tables[0].fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqual(@as(usize, 0), fields[0].directives.len);
    try std.testing.expectEqual(@as(usize, 2), fields[1].directives.len);
}

test "parser brace indentation is independent of indentation bodies" {
    for ([_][]const u8{
        "   T {\n a int =\n   #name `a`\n             }\n",
        "T {\na int =\n  #name `a`\n  }\n",
        "T {\na int =\n  #name `a`\n    }\n",
    }) |source| {
        var result = try parse(std.testing.allocator, source);
        try std.testing.expect(result == .schema);
        defer result.schema.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.schema.schema.tables[0].fields[0].directives.len);
    }
}

test "parser rejects unsupported syntax, incomplete constructs and invalid scope rules" {
    const sources = [_][]const u8{
        "T",                        "T {",                                      "T {\na",                            "T {\na int(",                                     "T {\na int(1",                      "T {\na int {",                    "T {\na int =",
        "T\n{}",                    "T { a int }",                              "T {\na int }",                      "T {\na int b int\n}",                             "T {\na int {\n} =\n  #name `a`\n}", "T {\na int = {\n}\n}",            "T {\na int |\n  #name `a`\n}",
        "T {\na int =\n}\n",        "T {\na int =\n -- wrong indentation\n}\n", "T {\na int =\n   #name `a`\n}\n",   "T {\na int =\n  #name `a`\n   #allow reuse\n}\n", "T {\n\ta int\n}\n",                 "--- unattached\n",                "--- detached\n\nT {}",
        "T {\n--- unattached\n}\n", "T {\n--- directive docs\n#name `t`\n}\n",  "T {\na int =\n  --- doc-only\n}\n", "T {\na int --- inline\n}\n",                      "T {\n#allow reuse\n}\n",            "T {\na int {\n#index {}\n}\n}\n", "type Foo {}",
        "enum Foo {}",              "T {\n_a int\n_ int\n}\n",                  "T {\ntrue int\n}\n",                "T {\na null\n}\n",                                "T {\na bool(TRUE)\n}\n",            "T {\na int(random())\n}\n",       "T {\na int(1 + 2)\n}\n",
        "T {\na real(1e3)\n}\n",    "T {\na real(.5)\n}\n",                     "T {\na str(\"x\")\n}\n",            "T {\na str('multi\nline')\n}\n",                  "T {\n#name `unterminated\n}\n",     "T {\na int!\n}\n",                "T {\na int #name `a`\n}\n",
        "T {\na int;\n}\n",
    };
    for (sources) |source| _ = try expectDiagnostic(source);
}

test "parser diagnostic spans identify exact offending tokens" {
    const unsupported = "T {\n  a int {\n    #index {}\n  }\n}\n";
    const d = try expectDiagnostic(unsupported);
    try std.testing.expectEqualStrings("index", unsupported[d.span.start..d.span.end]);
    const misplaced = "T {\n a int =\n    #name `a`\n}\n";
    const indent = try expectDiagnostic(misplaced);
    try std.testing.expectEqualStrings("#", misplaced[indent.span.start..indent.span.end]);
    const eof = "T {\n";
    const incomplete = try expectDiagnostic(eof);
    try std.testing.expectEqual(eof.len, incomplete.span.start);
    try std.testing.expectEqual(eof.len, incomplete.span.end);
    const docs = "--- detached\n\nT {}";
    const unattached = try expectDiagnostic(docs);
    try std.testing.expectEqualStrings("--- detached", docs[unattached.span.start..unattached.span.end]);
}

fn allocationSuccess(allocator: std.mem.Allocator) !void {
    var result = try parse(allocator, "--- table\n--- docs\nT {\n#name `t`\n--- field\na str('v') =\n  #name `a`\n  #allow reuse\nb int {}\n}\n");
    try std.testing.expect(result == .schema);
    result.schema.deinit();
}

fn allocationDiagnostic(allocator: std.mem.Allocator) !void {
    var result = try parse(allocator, "--- table\n--- docs\nT {\n#name `t`\n--- field\na str('v') =\n  #name `a`\n  #allow reuse\nb int {}\n#index {}\n}\n");
    if (result == .schema) {
        result.schema.deinit();
        return error.ExpectedDiagnostic;
    }
}

test "parser reclaims arena on all allocation failures and syntax failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationSuccess, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationDiagnostic, .{});
}
