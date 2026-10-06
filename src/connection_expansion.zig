//! Resolver-owned expansion. Source fields/docs stay untouched; generated keys
//! precede explicit payload in header order (canonical order for unnamed pairs),
//! regardless of the marker slot.
const std = @import("std");
const parsed = @import("model/parsed.zig");

fn part(ctx: anytype, out: *std.ArrayList(u8), text: []const u8, pascal: bool, span: parsed.Span) @TypeOf(ctx.*).Error!void {
    var first = true;
    var separator = false;
    for (text) |c| {
        if (c == '_') {
            separator = true;
            continue;
        }
        const byte = if (first) (if (pascal) std.ascii.toUpper(c) else std.ascii.toLower(c)) else if (separator) std.ascii.toUpper(c) else c;
        try out.append(ctx.allocator, byte);
        first = false;
        separator = false;
    }
    if (first) return ctx.fail(.invalid_connection, span, "Generated key name is unrepresentable; declare explicit roles/keys");
}

pub fn expand(ctx: anytype, source: parsed.Schema) @TypeOf(ctx.*).Error!parsed.Schema {
    const needed = for (source.tables) |table| {
        if (table.connection) |connection| if (connection.unnamed or connection.generated_keys_span != null) break true;
    } else false;
    if (!needed) return source;
    const tables = try ctx.allocator.dupe(parsed.Table, source.tables);
    // Canonicalize a private copy, without mutating source headers or fields.
    for (tables, 0..) |*table, ti| {
        const connection = table.connection orelse continue;
        if (!connection.unnamed) continue;
        if (connection.endpoints.len != 2 or connection.endpoints[0].role != null or connection.endpoints[1].role != null)
            return ctx.fail(.unsupported_feature, connection.span, "Unnamed connections support exactly two distinct unroled endpoints");
        const identity = @import("connection_identity.zig").canonicalKey(connection.endpoints[0].table.text, connection.endpoints[1].table.text) catch
            return ctx.fail(.unsupported_feature, connection.span, "Unnamed connections support exactly two distinct unroled endpoints");
        for (tables[0..ti]) |prior| {
            const other = prior.connection orelse continue;
            if (!other.unnamed) continue;
            const key = @import("connection_identity.zig").canonicalKey(other.endpoints[0].table.text, other.endpoints[1].table.text) catch unreachable;
            if (identity.eql(key)) return ctx.fail(.duplicate_dsl_name, connection.span, "Duplicate unnamed connection identity");
        }
        const endpoints = try ctx.allocator.dupe(parsed.Endpoint, connection.endpoints);
        if (!std.mem.eql(u8, endpoints[0].table.text, identity.endpoints[0])) std.mem.swap(parsed.Endpoint, &endpoints[0], &endpoints[1]);
        table.connection.?.endpoints = endpoints;
        table.name.text = try identity.declarationName(ctx.allocator);
        table.name.span = connection.span;
    }
    // Keep ordinary duplicate diagnostics independent of generated overrides.
    for (tables, 0..) |table, ti| {
        for (tables[0..ti]) |prior| if (std.mem.eql(u8, prior.name.text, table.name.text))
            return ctx.fail(.duplicate_dsl_name, table.name.span, "duplicate DSL table name");
        for (table.fields, 0..) |field, fi| for (table.fields[0..fi]) |prior| {
            if (std.mem.eql(u8, field.name.text, prior.name.text))
                return ctx.fail(.duplicate_dsl_name, field.name.span, "duplicate DSL field name");
        };
    }
    for (tables) |*table| {
        const connection = table.connection orelse continue;
        const marker = connection.generated_keys_span orelse continue;
        const fields = try ctx.allocator.alloc(parsed.Field, connection.endpoints.len + table.fields.len);
        for (connection.endpoints, 0..) |endpoint, ei| {
            for (connection.endpoints[0..ei]) |prior| {
                if (endpoint.role) |role| if (prior.role) |other| {
                    if (std.mem.eql(u8, role.text, other.text)) return ctx.fail(.invalid_connection, role.span, "Duplicate connection endpoint role");
                };
            }
            var occurrences: usize = 0;
            for (connection.endpoints) |other| if (std.mem.eql(u8, other.table.text, endpoint.table.text)) {
                occurrences += 1;
            };
            if (occurrences > 1 and endpoint.role == null)
                return ctx.fail(.invalid_connection, endpoint.span, "Repeated connection endpoints require unique roles");
            const parent = for (source.tables) |candidate| {
                if (std.mem.eql(u8, candidate.name.text, endpoint.table.text)) break candidate;
            } else return ctx.fail(.invalid_connection, endpoint.table.span, "Unknown connection endpoint table");
            if (parent.connection != null) return ctx.fail(.unsupported_feature, endpoint.table.span, "Nested connection endpoints are unsupported");
            var key: ?parsed.Field = null;
            for (parent.fields) |field| if (field.primary_key) {
                if (key != null) return ctx.fail(.invalid_connection, endpoint.span, "Generated connection endpoint requires exactly one declared primary key");
                key = field;
            };
            const pk = key orelse return ctx.fail(.invalid_connection, endpoint.span, "Generated connection endpoint requires exactly one declared primary key");
            var name: std.ArrayList(u8) = .empty;
            try part(ctx, &name, (endpoint.role orelse endpoint.table).text, false, endpoint.span);
            try part(ctx, &name, pk.name.text, true, endpoint.span);
            const text = try name.toOwnedSlice(ctx.allocator);
            if (!@import("unique.zig").dslName(text)) return ctx.fail(.invalid_connection, endpoint.span, "Generated key name is unrepresentable; declare explicit roles/keys");
            for (fields[0..ei]) |prior| if (std.mem.eql(u8, prior.name.text, text))
                return ctx.fail(.invalid_connection, endpoint.span, "Generated connection key names collide; declare distinct roles/keys");
            fields[ei] = .{ .name = .{ .text = text, .span = endpoint.span }, .type = .{ .name = endpoint.table, .span = endpoint.table.span }, .primary_key = true, .foreign_key = true, .span = marker };
            for (table.fields) |field| {
                if (!std.mem.eql(u8, field.name.text, text)) continue;
                if (!field.foreign_key)
                    return ctx.fail(.invalid_connection, field.name.span, "Generated key override must retain its stored foreign-key role");
                if (!field.primary_key)
                    return ctx.fail(.invalid_connection, field.name.span, "Generated key override must retain its primary-key role");
                if (field.type.nullable)
                    return ctx.fail(.invalid_connection, field.type.span, "Generated key override must be nonnullable");
                if (!std.mem.eql(u8, field.type.name.text, endpoint.table.text))
                    return ctx.fail(.invalid_connection, field.type.name.span, "Generated key override must target its exact DSL endpoint table");
                for (field.directives) |directive| if (directive.kind == .allow_reuse)
                    return ctx.fail(.invalid_connection, directive.span, "Generated key override cannot use #allow reuse");
                // Preserve the authored metadata as a whole, in the generated slot.
                // Its slices remain read-only and are owned by the source arena.
                fields[ei] = field;
            }
        }
        var length = connection.endpoints.len;
        for (table.fields) |field| {
            const overridden = for (fields[0..connection.endpoints.len]) |generated| {
                if (std.mem.eql(u8, field.name.text, generated.name.text)) break true;
            } else false;
            if (overridden) continue;
            fields[length] = field;
            length += 1;
        }
        table.fields = fields[0..length];
    }
    return .{ .tables = tables };
}
