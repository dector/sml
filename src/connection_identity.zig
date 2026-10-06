//! Canonical unnamed identity is the sorted DSL table-name multiset.
//! Repeated tables are retained; endpoint roles and SQL aliases are excluded.
const std = @import("std");

pub const Identity = struct {
    endpoints: []const []const u8,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.order(b) == .eq;
    }

    pub fn order(a: Identity, b: Identity) std.math.Order {
        for (a.endpoints[0..@min(a.endpoints.len, b.endpoints.len)], b.endpoints[0..@min(a.endpoints.len, b.endpoints.len)]) |x, y| {
            const result = std.mem.order(u8, x, y);
            if (result != .eq) return result;
        }
        return std.math.order(a.endpoints.len, b.endpoints.len);
    }

    pub fn declarationName(self: Identity, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.mem.join(allocator, "__n__", self.endpoints);
    }
};

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Own both the component array and its strings in the caller's arena.
pub fn canonicalKey(allocator: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error!Identity {
    const components = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |name, i| components[i] = try allocator.dupe(u8, name);
    std.mem.sort([]const u8, components, {}, less);
    return .{ .endpoints = components };
}

pub fn fromEndpoints(allocator: std.mem.Allocator, endpoints: anytype) std.mem.Allocator.Error!Identity {
    const names = try allocator.alloc([]const u8, endpoints.len);
    for (endpoints, 0..) |endpoint, i| names[i] = endpoint.table.text;
    return canonicalKey(allocator, names);
}

pub fn endpointLess(_: void, a: @import("model/parsed.zig").Endpoint, b: @import("model/parsed.zig").Endpoint) bool {
    const order = std.mem.order(u8, a.table.text, b.table.text);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, if (a.role) |role| role.text else "", if (b.role) |role| role.text else "") == .lt;
}
