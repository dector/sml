//! UTC second-precision timestamps, without SQLite's permissive date parsing.
const std = @import("std");

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
    const year = number(text[0..4]);
    const month = number(text[5..7]);
    const day = number(text[8..10]);
    if (year == 0 or month < 1 or month > 12 or day < 1) return false;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const days: u16 = switch (month) {
        2 => if (leap) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    return day <= days and number(text[11..13]) < 24 and number(text[14..16]) < 60 and number(text[17..19]) < 60;
}

fn number(digits: []const u8) u16 {
    var result: u16 = 0;
    for (digits) |digit| result = result * 10 + digit - '0';
    return result;
}

/// Every @ is replaced with the quoted column identifier by the emitter.
/// Character length plus explicit NUL rejection works with all SQLite encodings.
pub const check = " CHECK (@ IS NULL OR (typeof(@) = 'text' AND length(@) = 20 AND instr(@, char(0)) = 0" ++
    " AND @ GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'" ++
    " AND substr(@, 1, 4) BETWEEN '0001' AND '9999'" ++
    " AND substr(@, 6, 2) BETWEEN '01' AND '12'" ++
    " AND CAST(substr(@, 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr(@, 6, 2) AS INTEGER)" ++
    " WHEN 2 THEN 28 + (CAST(substr(@, 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr(@, 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr(@, 1, 4) AS INTEGER) % 400 = 0))" ++
    " WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END" ++
    " AND substr(@, 12, 2) BETWEEN '00' AND '23'" ++
    " AND substr(@, 15, 2) BETWEEN '00' AND '59'" ++
    " AND substr(@, 18, 2) BETWEEN '00' AND '59'))";
