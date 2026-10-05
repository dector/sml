//! Shared SQLite quoting. Callers validate identifiers before writing.
const std = @import("std");

/// char(0) rather than CAST(UTF-8 blob AS TEXT): SQLite blob casts use the
/// database encoding and corrupt UTF-8 bytes in UTF-16 databases.
pub fn writeText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    const has_nul = std.mem.indexOfScalar(u8, text, 0) != null;
    if (has_nul) try writer.writeByte('(');
    var pieces = std.mem.splitScalar(u8, text, 0);
    var first = true;
    while (pieces.next()) |piece| {
        if (!first) try writer.writeAll(" || char(0) || ");
        first = false;
        try writer.writeByte('\'');
        for (piece) |byte| {
            try writer.writeByte(byte);
            if (byte == '\'') try writer.writeByte('\'');
        }
        try writer.writeByte('\'');
    }
    if (has_nul) try writer.writeByte(')');
}

pub fn writeBlob(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    try writer.writeAll("X'");
    for (bytes) |byte| {
        try writer.writeByte(hex[byte >> 4]);
        try writer.writeByte(hex[byte & 0x0f]);
    }
    try writer.writeByte('\'');
}

pub fn writeIdentifier(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (name) |byte| {
        try writer.writeByte(byte);
        if (byte == '"') try writer.writeByte('"');
    }
    try writer.writeByte('"');
}
