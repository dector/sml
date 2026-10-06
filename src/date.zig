//! Canonical Gregorian calendar days, independent of timezones and SQLite parsing.
const std = @import("std");

pub fn valid(text: []const u8) bool {
    if (text.len != 10) return false;
    for (text, 0..) |byte, i| {
        if (i == 4 or i == 7) {
            if (byte != '-') return false;
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
    return day <= days;
}

pub fn number(digits: []const u8) u16 {
    var result: u16 = 0;
    for (digits) |digit| result = result * 10 + digit - '0';
    return result;
}

/// Shared canonical date-prefix constraints. Every @ is a quoted column.
pub const calendar_check = " AND substr(@, 1, 4) BETWEEN '0001' AND '9999'" ++
    " AND substr(@, 6, 2) BETWEEN '01' AND '12'" ++
    " AND CAST(substr(@, 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr(@, 6, 2) AS INTEGER)" ++
    " WHEN 2 THEN 28 + (CAST(substr(@, 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr(@, 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr(@, 1, 4) AS INTEGER) % 400 = 0))" ++
    " WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END";

/// Character length and explicit NUL rejection work in every SQLite encoding.
pub const check = " CHECK (@ IS NULL OR (typeof(@) = 'text' AND length(@) = 10 AND instr(@, char(0)) = 0" ++
    " AND @ GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'" ++ calendar_check ++ "))";
