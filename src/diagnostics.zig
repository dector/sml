//! Plain-text source diagnostics. Byte spans are zero-based and end-exclusive;
//! reported locations are one-based Unicode code-point columns (not graphemes
//! or terminal cell widths). Tabs count as one location column, but render at
//! four-column stops. Invalid UTF-8 bytes count as one column and render as \xHH.
//! Excerpts are bounded; this module allocates no memory and emits no ANSI.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const resolver = @import("resolver.zig");

pub const Error = std.Io.Writer.Error || error{InvalidSpan};

/// Invalid spans fail before writing anything. Other writer failures can leave
/// partial output. Null category omits the bracketed label. Byte offsets inside
/// a UTF-8 sequence point to that code point. LF, CRLF and lone CR are newlines;
/// offsets inside CRLF point to the end of the preceding line.
pub fn format(writer: *std.Io.Writer, source_name: []const u8, source: []const u8, span: parsed.Span, message: []const u8, category: ?[]const u8) Error!void {
    if (span.start > span.end or span.end > source.len) return error.InvalidSpan;
    var line: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < span.start) {
        if (source[i] == '\n' or source[i] == '\r') {
            const end = i + if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') @as(usize, 2) else @as(usize, 1);
            if (end > span.start) break;
            line += 1;
            line_start = end;
            i = end;
        } else i += unit(source[i..], 0).len;
    }
    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\r' and source[line_end] != '\n') : (line_end += 1) {}
    const point = @min(span.start, line_end);
    var column: usize = 1;
    var visual: usize = 0;
    i = line_start;
    while (i < point) {
        const u = unit(source[i..line_end], visual);
        if (i + u.len > point) break;
        visual += u.width;
        column += 1;
        i += u.len;
    }
    const caret_byte = i;
    const caret_column = visual;
    const window_start = caret_column -| 40;
    const window_end = caret_column +| 120;
    // Snap excerpt boundaries to complete rendered code points/escapes/tabs.
    var excerpt_start = line_start;
    var excerpt_end = line_start;
    var excerpt_column: usize = 0;
    var excerpt_width: usize = 0;
    var highlight_end = caret_column;
    visual = 0;
    i = line_start;
    while (i < line_end) {
        const u = unit(source[i..line_end], visual);
        if (visual < window_start) {
            excerpt_start = i + u.len;
            excerpt_column = visual + u.width;
        } else if (visual + u.width <= window_end) {
            excerpt_end = i + u.len;
            excerpt_width += u.width;
        } else break;
        if (i >= caret_byte and i < span.end) highlight_end = visual + u.width;
        visual += u.width;
        i += u.len;
    }
    excerpt_end = @max(excerpt_start, excerpt_end);
    const left_clip = excerpt_start != line_start;
    const right_clip = excerpt_end != line_end;
    try safeText(writer, source_name);
    try writer.print(":{d}:{d}: error", .{ line, column });
    if (category) |label| {
        try writer.writeAll(" [");
        try safeText(writer, label);
        try writer.writeByte(']');
    }
    try writer.writeAll(": ");
    try safeText(writer, message);
    try writer.writeAll("\n  ");
    if (left_clip) try writer.writeAll("...");
    visual = excerpt_column;
    i = excerpt_start;
    while (i < excerpt_end) {
        const u = unit(source[i..excerpt_end], visual);
        try render(writer, source[i..][0..u.len], u);
        visual += u.width;
        i += u.len;
    }
    if (right_clip) try writer.writeAll("...");
    try writer.writeAll("\n  ");
    const indent = caret_column - excerpt_column + @as(usize, if (left_clip) 3 else 0);
    try repeat(writer, ' ', indent);
    const available = excerpt_width -| (caret_column - excerpt_column);
    const width = @max(@as(usize, 1), @min(highlight_end -| caret_column, available));
    try writer.writeByte('^');
    try repeat(writer, '~', width - 1);
    try writer.writeByte('\n');
    if (span.end > span.start and span.end > line_end and line_end < source.len)
        try writer.writeAll("note: span continues beyond this line\n");
}

pub fn formatParser(writer: *std.Io.Writer, source_name: []const u8, source: []const u8, diagnostic: parsed.Diagnostic) Error!void {
    return format(writer, source_name, source, diagnostic.span, diagnostic.message, "syntax");
}

pub fn formatResolver(writer: *std.Io.Writer, source_name: []const u8, source: []const u8, diagnostic: resolver.Diagnostic) Error!void {
    return format(writer, source_name, source, diagnostic.span, diagnostic.message, @tagName(diagnostic.category));
}

const Unit = struct { len: usize, width: usize, escape: enum { none, byte, unicode, tab }, codepoint: u21 = 0 };
fn unit(text: []const u8, column: usize) Unit {
    const byte = text[0];
    if (byte == '\t') return .{ .len = 1, .width = 4 - column % 4, .escape = .tab };
    const len = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .len = 1, .width = 4, .escape = .byte };
    if (len > text.len) return .{ .len = 1, .width = 4, .escape = .byte };
    const cp = std.unicode.utf8Decode(text[0..len]) catch return .{ .len = 1, .width = 4, .escape = .byte };
    if (cp < 32 or cp == 127) return .{ .len = 1, .width = 4, .escape = .byte };
    // C1 terminal controls, bidi controls and Unicode line separators.
    if ((cp >= 0x80 and cp <= 0x9f) or cp == 0x61c or cp == 0x200e or cp == 0x200f or (cp >= 0x2028 and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) {
        var digits: usize = 1;
        var n = cp;
        while (n >= 16) : (n >>= 4) digits += 1;
        return .{ .len = len, .width = digits + 4, .escape = .unicode, .codepoint = cp };
    }
    return .{ .len = len, .width = 1, .escape = .none };
}
fn render(writer: *std.Io.Writer, text: []const u8, u: Unit) std.Io.Writer.Error!void {
    switch (u.escape) {
        .none => try writer.writeAll(text),
        .byte => try writer.print("\\x{X:0>2}", .{text[0]}),
        .unicode => try writer.print("\\u{{{X}}}", .{u.codepoint}),
        .tab => try repeat(writer, ' ', u.width),
    }
}
fn safeText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        var u = unit(text[i..], 0);
        // Header strings must never inject physical lines or literal tabs.
        if (u.escape == .tab) u = .{ .len = 1, .width = 4, .escape = .byte };
        try render(writer, text[i..][0..u.len], u);
        i += u.len;
    }
}
fn repeat(writer: *std.Io.Writer, byte: u8, count: usize) std.Io.Writer.Error!void {
    for (0..count) |_| try writer.writeByte(byte);
}
