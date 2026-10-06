//! UTC second-precision timestamps, without SQLite's permissive date parsing.
const std = @import("std");
const date = @import("date.zig");

pub fn valid(text: []const u8) bool {
    if (text.len != 20) return false;
    for (text, 0..) |byte, i| {
        const separator: ?u8 = switch (i) {
            4, 7 => '-',
            10 => 'T',
            13, 16 => ':',
            19 => 'Z',
            else => null,
        };
        if (separator) |expected| {
            if (byte != expected) return false;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    return date.valid(text[0..10]) and date.number(text[11..13]) < 24 and date.number(text[14..16]) < 60 and date.number(text[17..19]) < 60;
}

/// Every @ is replaced with the quoted column identifier by the emitter.
/// Character length plus explicit NUL rejection works with all SQLite encodings.
pub const check = " CHECK (@ IS NULL OR (typeof(@) = 'text' AND length(@) = 20 AND instr(@, char(0)) = 0" ++
    " AND @ GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'" ++
    date.calendar_check ++
    " AND substr(@, 12, 2) BETWEEN '00' AND '23'" ++
    " AND substr(@, 15, 2) BETWEEN '00' AND '59'" ++
    " AND substr(@, 18, 2) BETWEEN '00' AND '59'))";
