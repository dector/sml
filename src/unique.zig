//! Order-independent equality for validated unique column sets.
const std = @import("std");
pub fn sameFields(a: []const usize, b: []const usize) bool {
    if (a.len != b.len) return false;
    for (a) |index| if (std.mem.indexOfScalar(usize, b, index) == null) return false;
    return true;
}
