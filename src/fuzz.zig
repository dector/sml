//! Bounded deterministic mutation fuzzing, not coverage-guided fuzzing.
const std = @import("std");
const compiler = @import("sml");

pub const source_capacity = 8192;
pub const corpus = [_][]const u8{
    @embedFile("testdata/parser/subset.sml"),
    @embedFile("testdata/parser/documentation.sml"),
    @embedFile("testdata/parser/enum.sml"),
    @embedFile("testdata/parser/date.sml"),
    @embedFile("testdata/parser/datetime.sml"),
    @embedFile("testdata/parser/named_checks.sml"),
    @embedFile("testdata/parser/partial_index.sml"),
    @embedFile("testdata/parser/foreign_keys.sml"),
    @embedFile("testdata/parser/direct_relationships.sml"),
    @embedFile("testdata/parser/named_connections.sml"),
    @embedFile("testdata/parser/generated_connections.sml"),
    @embedFile("testdata/parser/implicit_connections.sml"),
};
const tokens = [_][]const u8{ "{", "}", "\n", "  ", "#name `x`", "?? a <= b", "#check _ != null", "int?", "str", "enum", "::now", "->", "-- comment\r\n", "#`raw`#", "`unterminated", "\x00\x1b\xff\xc0\x80", "=", "!", "&&", "||", "(", ")", "#of a,b" };

// Explicit SplitMix64 algorithm: stable across Zig versions and target platforms.
const Rng = struct {
    state: u64,
    fn next(self: *Rng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
    fn below(self: *Rng, n: usize) usize {
        return @intCast(self.next() % @as(u64, @intCast(n)));
    }
};

fn append(buffer: []u8, len: *usize, text: []const u8) void {
    const n = @min(text.len, buffer.len - len.*);
    @memcpy(buffer[len.*..][0..n], text[0..n]);
    len.* += n;
}
fn insert(buffer: []u8, len: *usize, at: usize, text: []const u8) void {
    const n = @min(text.len, buffer.len - len.*);
    std.mem.copyBackwards(u8, buffer[at + n .. len.* + n], buffer[at..len.*]);
    @memcpy(buffer[at..][0..n], text[0..n]);
    len.* += n;
}

/// Each index has an independent RNG stream. Replay never runs prior cases.
/// The buffer size is part of the replay identity (the CLI's --max-bytes).
pub fn generate(seed: u64, index: u64, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len > 0 and buffer.len <= source_capacity);
    var rng: Rng = .{ .state = seed ^ (index *% 0xd1342543de82ef95) };
    var len: usize = 0;
    switch (index % 32) {
        0 => { // Unmutated corpus keeps the complete pipeline reachable.
            append(buffer, &len, corpus[@intCast((index / 32) % corpus.len)]);
            return buffer[0..len];
        },
        1, 2, 3 => { // Just below, at and above the expression nesting limit.
            const depth: usize = 255 + @as(usize, @intCast(index % 32)) - 1;
            append(buffer, &len, "T {\n  n int {\n    ? ");
            for (0..depth) |_| append(buffer, &len, "(");
            append(buffer, &len, "_ > 0");
            for (0..depth) |_| append(buffer, &len, ")");
            append(buffer, &len, "\n  }\n}\n");
            return buffer[0..len];
        },
        4 => { // Flat comparator/Boolean chains test structural depth too.
            append(buffer, &len, "T {\n  n int {\n    ? _ > 0");
            for (0..257) |_| append(buffer, &len, " && _ > 0");
            append(buffer, &len, "\n  }\n}\n");
            return buffer[0..len];
        },
        5 => { // Exercise exact configured input bound with an unterminated string.
            append(buffer, &len, "T {\n  s str = `");
            @memset(buffer[len..], 'x');
            return buffer;
        },
        6 => {
            append(buffer, &len, "-- comment\x00\x1b\xff\r\nT {\n  s str = `\xc0\x80`\n}\n");
            return buffer[0..len];
        },
        7 => { // Entirely arbitrary bytes, not just near-valid syntax.
            len = rng.below(buffer.len + 1);
            for (buffer[0..len]) |*byte| byte.* = @truncate(rng.next());
            return buffer[0..len];
        },
        else => append(buffer, &len, corpus[rng.below(corpus.len)]),
    }
    const rounds = 1 + rng.below(12);
    for (0..rounds) |_| {
        const at = rng.below(len + 1);
        switch (rng.below(9)) {
            0 => if (at < len) { // deletion
                const n = 1 + rng.below(len - at);
                std.mem.copyForwards(u8, buffer[at .. len - n], buffer[at + n .. len]);
                len -= n;
            },
            1 => { // arbitrary byte insertion
                const byte = [_]u8{@truncate(rng.next())};
                insert(buffer, &len, at, &byte);
            },
            2 => if (at < len) {
                buffer[at] ^= @as(u8, 1) << @as(u3, @intCast(rng.below(8)));
            },
            3 => { // corpus splice
                const other = corpus[rng.below(corpus.len)];
                const start = rng.below(other.len);
                insert(buffer, &len, at, other[start..][0 .. 1 + rng.below(other.len - start)]);
            },
            4 => { // repeat delimiter/control characters
                var repeated: [512]u8 = undefined;
                const chars = "{}()`#\n\r\t\x00\xff";
                @memset(&repeated, chars[rng.below(chars.len)]);
                insert(buffer, &len, at, repeated[0 .. 1 + rng.below(repeated.len)]);
            },
            5 => len = at, // prefix trimming, including empty input
            6 => insert(buffer, &len, at, tokens[rng.below(tokens.len)]),
            7 => if (at < len) {
                buffer[at] = @truncate(rng.next());
            },
            8 => { // remove a prefix
                std.mem.copyForwards(u8, buffer[0 .. len - at], buffer[at..len]);
                len -= at;
            },
            else => unreachable,
        }
    }
    return buffer[0..len];
}

fn spanValid(source: []const u8, span: compiler.parsed.Span) !void {
    if (span.start > span.end or span.end > source.len) return error.InvalidDiagnosticSpan;
}
fn sanitized(text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.UnsanitizedDiagnostic;
    for (text) |byte| if ((byte < 32 and byte != '\n') or byte == 127) return error.UnsanitizedDiagnostic;
}

/// Source outlives the parsed arena; the resolved arena outlives emission.
/// OOM and emitter preflight errors are infrastructure/invariant failures,
/// never silently treated as invalid source.
pub fn exercise(allocator: std.mem.Allocator, source: []const u8) !void {
    var diagnostic: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostic.deinit();
    // Independently exercise safe rendering even if the parser rejects byte zero.
    try compiler.diagnostics.format(&diagnostic.writer, "fuzz\x1b\xff\n", source, .{ .start = source.len / 2, .end = source.len }, "bad\x00\xff\r", "fuzz\t");
    try sanitized(diagnostic.written());
    diagnostic.clearRetainingCapacity();
    var syntax = try compiler.parser.parse(allocator, source);
    if (syntax == .diagnostic) {
        try spanValid(source, syntax.diagnostic.span);
        try compiler.diagnostics.formatParser(&diagnostic.writer, "fuzz", source, syntax.diagnostic);
        try sanitized(diagnostic.written());
        return;
    }
    defer syntax.schema.deinit();
    var semantic = try compiler.resolver.resolve(allocator, syntax.schema.schema);
    if (semantic == .diagnostic) {
        try spanValid(source, semantic.diagnostic.span);
        try compiler.diagnostics.formatResolver(&diagnostic.writer, "fuzz", source, semantic.diagnostic);
        try sanitized(diagnostic.written());
        return;
    }
    defer semantic.schema.deinit();
    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();
    compiler.emitter.emit(semantic.schema.schema, &sql.writer) catch |err| {
        return if (err == error.WriteFailed) error.OutOfMemory else err;
    };
    // Do not impose SQL syntax/UTF-8 policy here: raw SQL is trusted and
    // documentation comments preserve source bytes. SQLite checks are separate.
}

/// A separate leak-sensitive allocator per case prevents accumulation and checks
/// all error paths after the parser/resolver arenas and writers are released.
pub fn runCase(source: []const u8) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const result = exercise(gpa.allocator(), source);
    const status = gpa.deinit();
    if (status == .leak) return error.LeakDetected;
    try result;
}

test "fixed seed replay and bounded mutations" {
    var a: [source_capacity]u8 = undefined;
    var b: [source_capacity]u8 = undefined;
    for (0..100) |index| {
        const first = generate(0x505a4c, index, &a);
        const replay = generate(0x505a4c, index, &b);
        try std.testing.expectEqualSlices(u8, first, replay);
        try exercise(std.testing.allocator, first);
    }
    try std.testing.expectEqualSlices(u8, corpus[0], generate(0x505a4c, 0, &a));
    try std.testing.expectEqual(@as(usize, source_capacity), generate(0x505a4c, 5, &a).len);
    for (1..33) |size| {
        try std.testing.expect(generate(42, 14, a[0..size]).len <= size);
    }
}

test "fixtures, invalid UTF-8 and expression limits" {
    for (corpus) |source| try runCase(source);
    try runCase("\xff\xc0\x80\x00\x1b");
    var buffer: [source_capacity]u8 = undefined;
    for (1..5) |index| try runCase(generate(1, index, &buffer));
}
