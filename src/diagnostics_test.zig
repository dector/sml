const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const parsed = @import("model/parsed.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");

fn golden(source: []const u8, span: parsed.Span, expected: []const u8) !void {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.format(&output.writer, "test.pzl", source, span, "bad", null);
    try std.testing.expectEqualStrings(expected, output.written());
}

test "diagnostics empty EOF points and zero length ranges" {
    try golden("", .{ .start = 0, .end = 0 }, "test.pzl:1:1: error: bad\n  \n  ^\n");
    try golden("abc", .{ .start = 3, .end = 3 }, "test.pzl:1:4: error: bad\n  abc\n     ^\n");
    try golden("abc\n", .{ .start = 4, .end = 4 }, "test.pzl:2:1: error: bad\n  \n  ^\n");
    try golden("abc", .{ .start = 1, .end = 1 }, "test.pzl:1:2: error: bad\n  abc\n   ^\n");
}

test "diagnostics CRLF lone CR and multiline first line underline" {
    try golden("a\r\nbc\r\nd", .{ .start = 4, .end = 5 }, "test.pzl:2:2: error: bad\n  bc\n   ^\n");
    try golden("a\rbc", .{ .start = 2, .end = 4 }, "test.pzl:2:1: error: bad\n  bc\n  ^~\n");
    try golden("abc\r\ndef", .{ .start = 1, .end = 7 }, "test.pzl:1:2: error: bad\n  abc\n   ^~\nnote: span continues beyond this line\n");
    try golden("a\r\nb", .{ .start = 2, .end = 2 }, "test.pzl:1:2: error: bad\n  a\n   ^\n");
}

test "diagnostics Unicode columns tabs combining codepoints and interior bytes" {
    try golden("é\t猫x", .{ .start = 6, .end = 7 }, "test.pzl:1:4: error: bad\n  é   猫x\n       ^\n");
    try golden("é\t猫x", .{ .start = 3, .end = 6 }, "test.pzl:1:3: error: bad\n  é   猫x\n      ^\n");
    try golden("éx", .{ .start = 1, .end = 2 }, "test.pzl:1:1: error: bad\n  éx\n  ^\n");
    try golden("e\u{301}x", .{ .start = 3, .end = 4 }, "test.pzl:1:3: error: bad\n  e\u{301}x\n    ^\n");
    try golden("\t\tx", .{ .start = 1, .end = 2 }, "test.pzl:1:2: error: bad\n          x\n      ^~~~\n");
}

test "diagnostics sanitize malformed UTF8 NUL ESC and Unicode controls" {
    try golden("a\x00\x1b\xff\xc2\x85\u{202e}z", .{ .start = 1, .end = 4 }, "test.pzl:1:2: error: bad\n  a\\x00\\x1B\\xFF\\u{85}\\u{202E}z\n   ^~~~~~~~~~~~\n");
    try golden("\xc3x", .{ .start = 0, .end = 1 }, "test.pzl:1:1: error: bad\n  \\xC3x\n  ^~~~\n");
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.format(&output.writer, "a\n\x1b\t", "", .{ .start = 0, .end = 0 }, "m\r\x00", "c\xff");
    try std.testing.expectEqualStrings("a\\x0A\\x1B\\x09:1:1: error [c\\xFF]: m\\x0D\\x00\n  \n  ^\n", output.written());
}

test "diagnostics invalid spans produce no writes" {
    for ([_]parsed.Span{ .{ .start = 2, .end = 1 }, .{ .start = 0, .end = 4 }, .{ .start = 4, .end = 4 }, .{ .start = 0, .end = std.math.maxInt(usize) } }) |span| {
        var bytes: [1]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectError(error.InvalidSpan, diagnostics.format(&writer, "test", "abc", span, "bad", null));
        try std.testing.expectEqualStrings("", writer.buffered());
    }
}

test "diagnostics huge lines are bounded around the span and EOF" {
    const source = try std.testing.allocator.alloc(u8, 10000);
    defer std.testing.allocator.free(source);
    @memset(source, 'a');
    for ([_]parsed.Span{ .{ .start = 5000, .end = 9000 }, .{ .start = 10000, .end = 10000 }, .{ .start = 0, .end = 10000 } }) |span| {
        var bytes: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try diagnostics.format(&writer, "test", source, span, "bad", null);
        try std.testing.expect(writer.buffered().len < 400);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "...") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "^") != null);
    }
}

test "diagnostics clipped excerpt and capped underline golden" {
    const source: [300]u8 = @splat('a');
    const expected = "test.pzl:1:101: error: bad\n  ..." ++ @as([160]u8, @splat('a')) ++ "...\n  " ++ @as([43]u8, @splat(' ')) ++ "^" ++ @as([119]u8, @splat('~')) ++ "\n";
    try golden(&source, .{ .start = 100, .end = 300 }, expected);
}

test "diagnostics every byte offset in untrusted text stays bounded" {
    var source: [256]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @intCast(index);
    for (0..source.len + 1) |point| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try diagnostics.format(&writer, "test", &source, .{ .start = point, .end = source.len }, "bad", null);
        for (writer.buffered()) |byte| try std.testing.expect(byte >= 32 or byte == '\n');
    }
}

test "diagnostics writer failure and allocating writer OOM propagate" {
    var bytes: [1]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&bytes);
    try std.testing.expectError(error.WriteFailed, diagnostics.format(&fixed, "test", "", .{ .start = 0, .end = 0 }, "bad", null));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var output = std.Io.Writer.Allocating.init(failing.allocator());
    defer output.deinit();
    try std.testing.expectError(error.WriteFailed, diagnostics.format(&output.writer, "test", "", .{ .start = 0, .end = 0 }, "bad", null));
}

test "diagnostics parser named check unknown option and EOF golden" {
    const source = "T {\n?? true {\n#unique\n}\n}\n";
    const result = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqualStrings("unique", source[result.diagnostic.span.start..result.diagnostic.span.end]);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.formatParser(&output.writer, "schema.pzl", source, result.diagnostic);
    try std.testing.expectEqualStrings("schema.pzl:3:2: error [syntax]: Only #name is supported in check options\n  #unique\n   ^~~~~~\n", output.written());
    output.clearRetainingCapacity();
    const eof_source = "T {\n?? true {\n#name `N`\n";
    const eof = try parser.parse(std.testing.allocator, eof_source);
    try std.testing.expect(eof == .diagnostic);
    try diagnostics.formatParser(&output.writer, "schema.pzl", eof_source, eof.diagnostic);
    try std.testing.expectEqualStrings("schema.pzl:4:1: error [syntax]: Expected '}' to close check options\n  \n  ^\n", output.written());
}

test "diagnostics resolver exact name and unknown field golden" {
    for ([_]struct { source: []const u8, token: []const u8, expected: []const u8 }{
        .{ .source = "T {\n?? true {\n#name ``\n}\n}\n", .token = "``", .expected = "schema.pzl:3:7: error [invalid_identifier]: SQL identifier must be nonempty UTF-8 and contain no NUL\n  #name ``\n        ^~\n" },
        .{ .source = "T {\na int\n?? missing > 0\n}\n", .token = "missing", .expected = "schema.pzl:3:4: error [invalid_check]: unknown DSL field name\n  ?? missing > 0\n     ^~~~~~~\n" },
    }) |case| {
        var syntax = try parser.parse(std.testing.allocator, case.source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        defer if (semantic == .schema) semantic.schema.deinit();
        try std.testing.expect(semantic == .diagnostic);
        try std.testing.expectEqualStrings(case.token, case.source[semantic.diagnostic.span.start..semantic.diagnostic.span.end]);
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try diagnostics.formatResolver(&output.writer, "schema.pzl", case.source, semantic.diagnostic);
        try std.testing.expectEqualStrings(case.expected, output.written());
    }
}
