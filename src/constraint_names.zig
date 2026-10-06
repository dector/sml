//! Table-local namespace shared by explicit UNIQUE and CHECK constraints.
const std = @import("std");
const resolved = @import("model/resolved.zig");
pub const Error = error{ InvalidIdentifier, SqlNameCollision };

fn nameAt(table: resolved.Table, wanted: usize) ?[]const u8 {
    var n: usize = 0;
    for (table.unique_constraints) |item| if (item.name) |name| {
        if (n == wanted) return name;
        n += 1;
    };
    for (table.checks) |item| if (item.name) |name| {
        if (n == wanted) return name;
        n += 1;
    };
    for (table.columns) |column| {
        for (column.unique_constraints) |item| if (item.name) |name| {
            if (n == wanted) return name;
            n += 1;
        };
        for (column.checks) |item| if (item.name) |name| {
            if (n == wanted) return name;
            n += 1;
        };
    }
    return null;
}

pub fn validate(table: resolved.Table) Error!void {
    var n: usize = 0;
    while (nameAt(table, n)) |name| : (n += 1) {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidIdentifier;
        var prior: usize = 0;
        while (prior < n) : (prior += 1) {
            if (std.ascii.eqlIgnoreCase(name, nameAt(table, prior).?)) return error.SqlNameCollision;
        }
    }
}
