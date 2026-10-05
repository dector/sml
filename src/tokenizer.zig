//! Allocation-free lexical scanner. Text (including literal/comment delimiters)
//! borrows source; spans are end-exclusive byte offsets. CRLF is one newline.
const std = @import("std");
const parsed = @import("model/parsed.zig");

pub const Kind = enum {
    identifier,
    boolean,
    integer,
    real,
    string,
    backtick,
    generator,
    l_brace,
    r_brace,
    l_paren,
    r_paren,
    bang,
    question,
    equal,
    hash,
    newline,
    comment,
    doc,
    eof,
};
pub const Token = struct { kind: Kind, text: []const u8, span: parsed.Span, indent: usize };
pub const Diagnostic = struct { message: []const u8, span: parsed.Span };
pub const Result = union(enum) { token: Token, diagnostic: Diagnostic };

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,
    indent: usize = 0,
    line_start: bool = true,
    line_has_token: bool = false,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    pub fn next(self: *Tokenizer) Result {
        if (self.line_start) {
            self.indent = 0;
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                self.pos += 1;
                self.indent += 1;
            }
            self.line_start = false;
            if (self.pos < self.source.len and self.source[self.pos] == '\t') {
                const start = self.pos;
                self.pos += 1;
                return self.fail(start, "tabs are not allowed in leading indentation");
            }
        }
        while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;
        const start = self.pos;
        if (start == self.source.len) return self.token(.eof, start);
        const c = self.source[self.pos];
        if (isNewline(c)) {
            self.pos += 1;
            if (c == '\r' and self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
            const result = self.token(.newline, start);
            self.line_start = true;
            self.line_has_token = false;
            return result;
        }
        const inline_token = self.line_has_token;
        self.line_has_token = true;
        if (isIdentifierStart(c)) {
            self.pos += 1;
            while (self.pos < self.source.len and isIdentifierContinue(self.source[self.pos])) self.pos += 1;
            const text = self.source[start..self.pos];
            return self.token(if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) .boolean else .identifier, start);
        }
        if (c == '-' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '-') {
            self.pos += 2;
            const doc = self.pos < self.source.len and self.source[self.pos] == '-';
            while (self.pos < self.source.len and !isNewline(self.source[self.pos])) self.pos += 1;
            if (doc and inline_token) return self.fail(start, "documentation comments must be standalone");
            return self.token(if (doc) .doc else .comment, start);
        }
        if (std.ascii.isDigit(c) or (c == '-' and self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1]))) return self.number(start);
        if (c == '\'' or c == '`') return self.literal(start, 0, c);
        if (c == '#') {
            var end = self.pos;
            while (end < self.source.len and self.source[end] == '#') end += 1;
            if (end < self.source.len and (self.source[end] == '\'' or self.source[end] == '`')) return self.literal(start, end - start, self.source[end]);
        }
        if (c == ':' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ':') {
            self.pos += 2;
            if (self.pos == self.source.len or !isIdentifierStart(self.source[self.pos]))
                return self.fail(start, "expected generator name after '::'");
            self.pos += 1;
            while (self.pos < self.source.len and isIdentifierContinue(self.source[self.pos])) self.pos += 1;
            return self.token(.generator, start);
        }
        self.pos += 1;
        return switch (c) {
            '{' => self.token(.l_brace, start),
            '}' => self.token(.r_brace, start),
            '(' => self.token(.l_paren, start),
            ')' => self.token(.r_paren, start),
            '!' => self.token(.bang, start),
            '?' => self.token(.question, start),
            '=' => self.token(.equal, start),
            '#' => self.token(.hash, start),
            '"' => self.fail(start, "double-quoted strings are not supported; use single quotes"),
            '.', '+' => self.fail(start, "invalid number syntax; use decimal digits with an optional leading minus"),
            '|' => self.fail(start, "pipe bodies are not supported; use '=' or braces"),
            else => self.fail(start, "invalid or unsupported character"),
        };
    }

    fn number(self: *Tokenizer, start: usize) Result {
        if (self.source[self.pos] == '-') self.pos += 1;
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
        var kind: Kind = .integer;
        var invalid = false;
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            kind = .real;
            self.pos += 1;
            const digits_start = self.pos;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
            invalid = self.pos == digits_start;
        }
        // Do not split exponents, hex, separators, or malformed decimals into
        // plausible independent tokens. Conversion/overflow belongs to resolution.
        if (self.pos < self.source.len and (isIdentifierContinue(self.source[self.pos]) or self.source[self.pos] == '.')) {
            invalid = true;
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (!isIdentifierContinue(c) and c != '.' and c != '+' and c != '-') break;
                self.pos += 1;
            }
        }
        if (invalid) return self.fail(start, "invalid number syntax; exponents, hex, and digit separators are not supported");
        return self.token(kind, start);
    }

    fn literal(self: *Tokenizer, start: usize, hashes: usize, quote: u8) Result {
        self.pos = start + hashes + 1;
        if (hashes > 0 and quote == '\'' and self.pos + 1 < self.source.len and self.source[self.pos] == '\'' and self.source[self.pos + 1] == '\'') {
            self.pos += 2;
            return self.fail(start, "multiline raw strings are not supported");
        }
        while (self.pos < self.source.len) {
            if (isNewline(self.source[self.pos])) return self.fail(start, "multiline literals are not supported");
            if (self.source[self.pos] != quote) {
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (hashes == 0) {
                if (quote == '\'' and self.pos < self.source.len and self.source[self.pos] == '\'') {
                    self.pos += 1;
                    continue;
                }
                return self.token(if (quote == '\'') .string else .backtick, start);
            }
            var end = self.pos;
            while (end < self.source.len and self.source[end] == '#') end += 1;
            if (end - self.pos == hashes) {
                self.pos = end;
                return self.token(if (quote == '\'') .string else .backtick, start);
            }
            self.pos = end;
        }
        return self.fail(start, "unterminated literal; expected matching closing delimiter");
    }

    fn token(self: *Tokenizer, kind: Kind, start: usize) Result {
        return .{ .token = .{ .kind = kind, .text = self.source[start..self.pos], .span = .{ .start = start, .end = self.pos }, .indent = self.indent } };
    }

    fn fail(self: *Tokenizer, start: usize, message: []const u8) Result {
        return .{ .diagnostic = .{ .message = message, .span = .{ .start = start, .end = self.pos } } };
    }
};

fn isNewline(c: u8) bool {
    return c == '\n' or c == '\r';
}
fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn isIdentifierContinue(c: u8) bool {
    return isIdentifierStart(c) or std.ascii.isDigit(c);
}

fn expectToken(scanner: *Tokenizer, kind: Kind, text: []const u8, indent: usize) !void {
    const result = scanner.next();
    try std.testing.expect(result == .token);
    const t = result.token;
    try std.testing.expectEqual(kind, t.kind);
    try std.testing.expectEqualStrings(text, t.text);
    try std.testing.expectEqual(indent, t.indent);
    try std.testing.expectEqualStrings(text, scanner.source[t.span.start..t.span.end]);
    try std.testing.expectEqual(@intFromPtr(scanner.source.ptr) + t.span.start, @intFromPtr(t.text.ptr));
}

test "identifiers, punctuation, indentation, line endings, and repeat EOF" {
    var s = Tokenizer.init("  Author {\r\n    _field2 ! str? = (#name)\n  }\r");
    try expectToken(&s, .identifier, "Author", 2);
    try expectToken(&s, .l_brace, "{", 2);
    try expectToken(&s, .newline, "\r\n", 2);
    try expectToken(&s, .identifier, "_field2", 4);
    try expectToken(&s, .bang, "!", 4);
    try expectToken(&s, .identifier, "str", 4);
    try expectToken(&s, .question, "?", 4);
    try expectToken(&s, .equal, "=", 4);
    try expectToken(&s, .l_paren, "(", 4);
    try expectToken(&s, .hash, "#", 4);
    try expectToken(&s, .identifier, "name", 4);
    try expectToken(&s, .r_paren, ")", 4);
    try expectToken(&s, .newline, "\n", 4);
    try expectToken(&s, .r_brace, "}", 2);
    try expectToken(&s, .newline, "\r", 2);
    try expectToken(&s, .eof, "", 0);
    try expectToken(&s, .eof, "", 0);
}

test "decimal numbers preserve spelling without converting or overflowing" {
    var s = Tokenizer.init("0 -12 001 1.25 -0.5 9999999999999999999999999999999");
    for ([_][]const u8{ "0", "-12", "001", "1.25", "-0.5", "9999999999999999999999999999999" }, [_]Kind{ .integer, .integer, .integer, .real, .real, .integer }) |text, kind| try expectToken(&s, kind, text, 0);
    try expectToken(&s, .eof, "", 0);
}

test "ordinary strings double quotes and keep backslashes and punctuation literal" {
    var s = Tokenizer.init("'it''s \\ -- {} # \\n' '' '''' `a--{}'\\` '\t' true false null");
    try expectToken(&s, .string, "'it''s \\ -- {} # \\n'", 0);
    try expectToken(&s, .string, "''", 0);
    try expectToken(&s, .string, "''''", 0);
    try expectToken(&s, .backtick, "`a--{}'\\`", 0);
    try expectToken(&s, .string, "'\t'", 0);
    for ([_][]const u8{ "true", "false" }) |text| try expectToken(&s, .boolean, text, 0);
    try expectToken(&s, .identifier, "null", 0);
}

test "hash delimiters require exact hash counts and distinguish directives" {
    var s = Tokenizer.init("#name #'a''b'# ##'x'#y'###z'## #`foo`bar`# ##`contains `# safely`##");
    try expectToken(&s, .hash, "#", 0);
    try expectToken(&s, .identifier, "name", 0);
    try expectToken(&s, .string, "#'a''b'#", 0);
    try expectToken(&s, .string, "##'x'#y'###z'##", 0);
    try expectToken(&s, .backtick, "#`foo`bar`#", 0);
    try expectToken(&s, .backtick, "##`contains `# safely`##", 0);
    try expectToken(&s, .eof, "", 0);
}

test "comments retain markers, docs retain spacing, and blank lines remain visible" {
    var s = Tokenizer.init("  ---  docs\n\n  -- ordinary\n  name -- inline\n");
    try expectToken(&s, .doc, "---  docs", 2);
    try expectToken(&s, .newline, "\n", 2);
    try expectToken(&s, .newline, "\n", 0);
    try expectToken(&s, .comment, "-- ordinary", 2);
    try expectToken(&s, .newline, "\n", 2);
    try expectToken(&s, .identifier, "name", 2);
    try expectToken(&s, .comment, "-- inline", 2);
    try expectToken(&s, .newline, "\n", 2);
}

test "invalid and unsupported syntax produces diagnostics" {
    const cases = [_][]const u8{
        ".5",              "1.",              "+1",           "1e3",          "1e-3",           "0x12",              "1_000",    "1.2.3",       "12abc",
        "\"text\"",        "|",               ";",            "@",            "-",              "\x00",              "\xc3\xa9", "'unfinished", "`unfinished",
        "#'unfinished'##", "##`unfinished`#", "'line\nnext'", "`line\rnext`", "#'line\nnext'#", "#'''multiline'''#", "\tfield",  "  \tfield",   "\t-- comment",
        "\t\n",
    };
    for (cases) |source| {
        var s = Tokenizer.init(source);
        const result = s.next();
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(result.diagnostic.message.len > 0);
        try std.testing.expect(result.diagnostic.span.end <= source.len);
    }
}

test "exact diagnostic spans and inline doc rejection" {
    var s = Tokenizer.init("name --- inline");
    try expectToken(&s, .identifier, "name", 0);
    const d = s.next().diagnostic;
    try std.testing.expectEqual(@as(usize, 5), d.span.start);
    try std.testing.expectEqual(@as(usize, 15), d.span.end);
    var n = Tokenizer.init("  1e+3");
    const nd = n.next().diagnostic;
    try std.testing.expectEqual(@as(usize, 2), nd.span.start);
    try std.testing.expectEqual(@as(usize, 6), nd.span.end);
    var l = Tokenizer.init("  'bad\n");
    const ld = l.next().diagnostic;
    try std.testing.expectEqual(@as(usize, 2), ld.span.start);
    try std.testing.expectEqual(@as(usize, 6), ld.span.end);
}

test "horizontal tabs between tokens and inside literals are allowed" {
    var s = Tokenizer.init("  a\tb\t#`\t`#\n");
    try expectToken(&s, .identifier, "a", 2);
    try expectToken(&s, .identifier, "b", 2);
    try expectToken(&s, .backtick, "#`\t`#", 2);
    try expectToken(&s, .newline, "\n", 2);
}
