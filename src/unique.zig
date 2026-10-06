//! Uniqueness proofs shared by resolution and public-model preflight.
const std = @import("std");
/// Proves at most one row per non-NULL value. Composite and partial keys
/// cannot prove this, even a partial index with a constant true predicate.
pub fn singleColumn(table: @import("model/resolved.zig").Table, ci: usize) bool {
    if (ci >= table.columns.len) return false;
    const column = table.columns[ci];
    if (column.primary_key != .none) {
        var count: usize = 0;
        for (table.columns) |c| if (c.primary_key != .none) {
            count += 1;
        };
        if (count == 1) return true;
    }
    for (column.unique_constraints) |u| if (u.columns.len == 0 and u.nulls == .distinct) return true;
    for (table.unique_constraints) |u| if (u.columns.len == 1 and u.columns[0] == ci and u.nulls == .distinct) return true;
    for (table.indexes) |i| if (i.unique and i.predicate == null and i.columns.len == 1 and i.columns[0] == ci) return true;
    return false;
}

/// Exact declaration identifier syntax; only Boolean literals are reserved.
pub fn dslName(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return !std.mem.eql(u8, name, "true") and !std.mem.eql(u8, name, "false");
}

pub fn sameFields(a: []const usize, b: []const usize) bool {
    if (a.len != b.len) return false;
    for (a) |index| if (std.mem.indexOfScalar(usize, b, index) == null) return false;
    return true;
}
