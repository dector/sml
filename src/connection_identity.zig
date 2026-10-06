//! Unnamed identity uses exact DSL endpoint names, never SQL names or the
//! synthesized declaration name. Only distinct, unroled pairs are supported.
const std = @import("std");

pub const Identity = struct {
    endpoints: [2][]const u8,

    pub fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, a.endpoints[0], b.endpoints[0]) and
            std.mem.eql(u8, a.endpoints[1], b.endpoints[1]);
    }

    pub fn declarationName(self: Identity, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}__n__{s}", .{ self.endpoints[0], self.endpoints[1] });
    }
};

/// Shared canonical key for this slice and future shorthand lookup.
pub fn canonicalKey(a: []const u8, b: []const u8) error{InvalidConnection}!Identity {
    return switch (std.mem.order(u8, a, b)) {
        .eq => error.InvalidConnection,
        .lt => .{ .endpoints = .{ a, b } },
        .gt => .{ .endpoints = .{ b, a } },
    };
}
