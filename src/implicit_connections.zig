//! Gather all shorthand identities before generating keys. Explicit unnamed
//! declarations win, independent of declaration order. Only private copies change.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const identity = @import("connection_identity.zig");
const Pending = struct { key: identity.Identity, span: parsed.Span };

fn less(_: void, a: Pending, b: Pending) bool {
    return a.key.order(b.key) == .lt;
}

fn find(tables: []const parsed.Table, key: identity.Identity) ?usize {
    for (tables, 0..) |table, i| {
        const connection = table.connection orelse continue;
        if (!connection.unnamed) continue;
        if (connection.endpoints.len != 2) continue;
        const a = connection.endpoints[0].table.text;
        const b = connection.endpoints[1].table.text;
        if ((std.mem.eql(u8, key.endpoints[0], a) and std.mem.eql(u8, key.endpoints[1], b)) or
            (std.mem.eql(u8, key.endpoints[0], b) and std.mem.eql(u8, key.endpoints[1], a))) return i;
    }
    return null;
}

pub fn expand(ctx: anytype, input: []parsed.Table) @TypeOf(ctx.*).Error![]parsed.Table {
    var pending: std.ArrayList(Pending) = .empty;
    for (input) |owner| for (owner.relationships) |r| {
        if (!r.source_implicit) continue;
        if (r.source_table.text.len != 0)
            return ctx.fail(.invalid_relationship_mapping, r.source_table.span, "Implicit source table must be empty");
        const key = try identity.canonicalKey(ctx.allocator, &.{ owner.name.text, r.target.name.text });
        for (key.endpoints) |name| {
            const parent = for (input) |candidate| {
                if (std.mem.eql(u8, candidate.name.text, name)) break candidate;
            } else return ctx.fail(.invalid_connection, r.source_field.span, "Unknown implicit connection endpoint table");
            if (parent.connection != null)
                return ctx.fail(.unsupported_feature, r.source_field.span, "Implicit connection endpoints must be normal tables");
            var keys: usize = 0;
            for (parent.fields) |field| if (field.primary_key) {
                keys += 1;
            };
            if (keys != 1)
                return ctx.fail(.invalid_connection, r.source_field.span, "Implicit connection endpoint requires exactly one declared primary key");
        }
        if (find(input, key) != null) continue;
        if (std.mem.eql(u8, key.endpoints[0], key.endpoints[1]))
            return ctx.fail(.invalid_connection, r.source_field.span, "Implicit self relationships require an explicit unnamed connection with distinct roles");
        const exists = for (pending.items) |prior| {
            if (key.eql(prior.key)) break true;
        } else false;
        if (!exists) try pending.append(ctx.allocator, .{ .key = key, .span = r.span });
    };
    std.mem.sort(Pending, pending.items, {}, less);
    const tables = try ctx.allocator.alloc(parsed.Table, input.len + pending.items.len);
    @memcpy(tables[0..input.len], input);
    for (pending.items, input.len..) |pair, i| {
        const endpoints = try ctx.allocator.alloc(parsed.Endpoint, 2);
        for (pair.key.endpoints, 0..) |name, ei| {
            const token = for (input) |table| {
                if (std.mem.eql(u8, table.name.text, name)) break table.name;
            } else unreachable;
            endpoints[ei] = .{ .table = token, .span = token.span };
        }
        tables[i] = .{
            .name = .{ .text = try pair.key.declarationName(ctx.allocator), .span = pair.span },
            .connection = .{ .unnamed = true, .endpoints = endpoints, .generated_keys_span = pair.span, .span = pair.span },
            .span = pair.span,
        };
    }
    for (tables[0..input.len]) |*table| {
        const needed = for (table.relationships) |r| {
            if (r.source_implicit) break true;
        } else false;
        if (!needed) continue;
        const relationships = try ctx.allocator.dupe(parsed.Relationship, table.relationships);
        for (relationships) |*r| {
            if (!r.source_implicit) continue;
            const key = try identity.canonicalKey(ctx.allocator, &.{ table.name.text, r.target.name.text });
            const index = find(tables, key) orelse unreachable;
            r.source_table = tables[index].name;
            r.source_implicit = false;
        }
        table.relationships = relationships;
    }
    return tables;
}
