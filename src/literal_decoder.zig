//! Shared semantic literal decoding. The caller supplies allocator and fail().
const std = @import("std");
const parsed = @import("model/parsed.zig");

pub fn backticks(context: anytype, token: parsed.Token) @TypeOf(context.*).Error![]const u8 {
    const text = token.text;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null)
        return context.fail(.unsupported_multiline, token.span, "multiline backticks are not supported yet");
    var hashes: usize = 0;
    while (hashes < text.len and text[hashes] == '#') : (hashes += 1) {}
    if (text.len < 2 * hashes + 2 or text[hashes] != '`')
        return context.fail(.invalid_literal, token.span, "expected matching backtick delimiters");
    const start = hashes + 1;
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] != '`') continue;
        var end = i + 1;
        while (end < text.len and text[end] == '#') : (end += 1) {}
        if (hashes == 0) end = i + 1 else if (end - i - 1 != hashes) continue;
        if (end != text.len)
            return context.fail(.invalid_literal, token.span, "backtick literal contains its closing delimiter");
        return text[start..i];
    }
    return context.fail(.invalid_literal, token.span, "expected matching backtick delimiters");
}

pub fn string(context: anytype, token: parsed.Token) @TypeOf(context.*).Error![]const u8 {
    const text = token.text;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null)
        return context.fail(.unsupported_multiline, token.span, "multiline string decoding is not supported yet");
    var hashes: usize = 0;
    while (hashes < text.len and text[hashes] == '#') : (hashes += 1) {}
    if (hashes > 0) {
        if (std.mem.startsWith(u8, text[hashes..], "'''"))
            return context.fail(.unsupported_multiline, token.span, "multiline raw string decoding is not supported yet");
        if (text.len < 2 * hashes + 2 or text[hashes] != '\'' or
            text[text.len - hashes - 1] != '\'' or !std.mem.eql(u8, text[0..hashes], text[text.len - hashes ..]))
            return context.fail(.invalid_literal, token.span, "raw string requires matching hash delimiters");
        const content_end = text.len - hashes - 1;
        var i = hashes + 1;
        while (i < text.len) : (i += 1) {
            if (text[i] != '\'') continue;
            var end = i + 1;
            while (end < text.len and text[end] == '#') : (end += 1) {}
            if (end - i - 1 != hashes) continue;
            if (i != content_end or end != text.len)
                return context.fail(.invalid_literal, token.span, "raw string contains its closing delimiter");
            return context.allocator.dupe(u8, text[hashes + 1 .. i]);
        }
        return context.fail(.invalid_literal, token.span, "raw string requires matching hash delimiters");
    }
    if (text.len < 2 or text[0] != '\'' or text[text.len - 1] != '\'')
        return context.fail(.invalid_literal, token.span, "text requires single-quote or hash delimiters");
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < text.len - 1) : (i += 1) {
        if (text[i] == '\'') {
            if (i + 1 >= text.len - 1 or text[i + 1] != '\'')
                return context.fail(.invalid_literal, token.span, "embedded single quotes must be doubled");
            i += 1;
        }
        try output.append(context.allocator, text[i]);
    }
    return output.toOwnedSlice(context.allocator);
}

pub fn integer(context: anytype, token: parsed.Token) @TypeOf(context.*).Error!i64 {
    return std.fmt.parseInt(i64, token.text, 10) catch
        return context.fail(.invalid_literal, token.span, "invalid or out-of-range integer literal");
}

pub fn real(context: anytype, token: parsed.Token) @TypeOf(context.*).Error!f64 {
    const number = std.fmt.parseFloat(f64, token.text) catch
        return context.fail(.invalid_literal, token.span, "invalid real literal");
    if (!std.math.isFinite(number)) return context.fail(.invalid_literal, token.span, "real literal must be finite");
    return number;
}

pub fn boolean(context: anytype, token: parsed.Token) @TypeOf(context.*).Error!bool {
    if (std.mem.eql(u8, token.text, "true")) return true;
    if (std.mem.eql(u8, token.text, "false")) return false;
    return context.fail(.invalid_literal, token.span, "expected true or false literal");
}

pub fn nullValue(context: anytype, token: parsed.Token) @TypeOf(context.*).Error!void {
    if (!std.mem.eql(u8, token.text, "null")) return context.fail(.invalid_literal, token.span, "expected null literal");
}

pub fn rawSql(context: anytype, token: parsed.Token) @TypeOf(context.*).Error![]const u8 {
    const sql = try backticks(context, token);
    if (sql.len == 0 or std.mem.indexOfScalar(u8, sql, 0) != null)
        return context.fail(.invalid_literal, token.span, "raw SQL must be nonempty and contain no NUL");
    return context.allocator.dupe(u8, sql);
}
