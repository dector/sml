//! Shared exact-byte enum validation for resolver and emitter boundaries.
const std = @import("std");

pub fn bare(text: []const u8) bool {
    if (text.len == 0 or std.mem.eql(u8, text, "null")) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

pub fn contains(values: []const []const u8, text: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, text)) return true;
    return false;
}

pub fn valid(values: []const []const u8) bool {
    if (values.len == 0) return false;
    for (values, 0..) |value, i| {
        if (!std.unicode.utf8ValidateSlice(value) or contains(values[0..i], value)) return false;
    }
    return true;
}
