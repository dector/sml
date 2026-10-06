//! Resolver-owned connection expansion. Nested endpoints copy the complete
//! target key in its stored order and retain a composite FK group, not independent
//! references to the leaf tables. Source fields/docs remain untouched.
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

fn keyName(ctx: anytype, prefix: parsed.Token, key: parsed.Token, span: parsed.Span) @TypeOf(ctx.*).Error!parsed.Token {
    var name: std.ArrayList(u8) = .empty;
    try part(ctx, &name, prefix.text, false, span);
    try part(ctx, &name, key.text, true, span);
    const text = try name.toOwnedSlice(ctx.allocator);
    if (!@import("unique.zig").dslName(text)) return ctx.fail(.invalid_connection, span, "Generated key name is unrepresentable; declare explicit roles/keys");
    return .{ .text = text, .span = span };
}

pub fn expand(ctx: anytype, source: parsed.Schema) @TypeOf(ctx.*).Error!parsed.Schema {
    const needed = needed: for (source.tables) |table| {
        if (table.connection != null) break :needed true;
        for (table.relationships) |relationship| if (relationship.source_implicit) break :needed true;
    } else false;
    if (!needed) return source;
    var tables = try ctx.allocator.dupe(parsed.Table, source.tables);
    for (tables, 0..) |*table, ti| {
        const connection = table.connection orelse continue;
        if (!connection.unnamed) continue;
        const identity = try @import("connection_identity.zig").fromEndpoints(ctx.allocator, connection.endpoints);
        for (tables[0..ti]) |prior| {
            const other = prior.connection orelse continue;
            if (!other.unnamed) continue;
            const key = try @import("connection_identity.zig").fromEndpoints(ctx.allocator, other.endpoints);
            if (identity.eql(key)) return ctx.fail(.duplicate_dsl_name, connection.span, "Duplicate unnamed connection identity");
        }
        const endpoints = try ctx.allocator.dupe(parsed.Endpoint, connection.endpoints);
        std.mem.sort(parsed.Endpoint, endpoints, {}, @import("connection_identity.zig").endpointLess);
        table.connection.?.endpoints = endpoints;
        table.name.text = try identity.declarationName(ctx.allocator);
        table.name.span = connection.span;
    }
    tables = try @import("implicit_connections.zig").expand(ctx, tables);
    for (tables, 0..) |table, ti| {
        for (tables[0..ti]) |prior| if (std.mem.eql(u8, prior.name.text, table.name.text))
            return ctx.fail(.duplicate_dsl_name, table.name.span, "duplicate DSL table name");
        for (table.fields, 0..) |field, fi| for (table.fields[0..fi]) |prior| {
            if (std.mem.eql(u8, field.name.text, prior.name.text))
                return ctx.fail(.duplicate_dsl_name, field.name.span, "duplicate DSL field name");
        };
    }
    const states = try ctx.allocator.alloc(u8, tables.len);
    @memset(states, 0);
    const heights = try ctx.allocator.alloc(usize, tables.len);
    @memset(heights, 0);
    for (tables, 0..) |_, ti| try expandTable(ctx, tables, states, heights, ti, 0);
    return .{ .tables = tables };
}

fn expandTable(ctx: anytype, tables: []parsed.Table, states: []u8, heights: []usize, ti: usize, depth: usize) @TypeOf(ctx.*).Error!void {
    if (states[ti] == 2) return;
    const connection = tables[ti].connection orelse {
        states[ti] = 2;
        return;
    };
    if (states[ti] == 1) return ctx.fail(.invalid_connection, connection.span, "Connection endpoint dependency cycle");
    if (depth > 256) return ctx.fail(.invalid_connection, connection.span, "Connection endpoint nesting exceeds 256 levels");
    states[ti] = 1;
    var height: usize = 1;
    for (connection.endpoints) |endpoint| {
        for (tables, 0..) |candidate, target| {
            if (!std.mem.eql(u8, candidate.name.text, endpoint.table.text)) continue;
            if (states[target] == 1) return ctx.fail(.invalid_connection, endpoint.table.span, "Connection endpoint dependency cycle");
            try expandTable(ctx, tables, states, heights, target, depth + 1);
            height = @max(height, heights[target] + 1);
            if (height > 256) return ctx.fail(.invalid_connection, endpoint.table.span, "Connection endpoint nesting exceeds 256 levels");
            break;
        }
    }
    if (connection.generated_keys_span) |marker| {
        var fields: std.ArrayList(parsed.Field) = .empty;
        const endpoints = try ctx.allocator.dupe(parsed.Endpoint, connection.endpoints);
        for (endpoints, 0..) |*endpoint, ei| {
            for (endpoints[0..ei]) |prior| {
                if (endpoint.role) |role| if (prior.role) |other| {
                    if (std.mem.eql(u8, role.text, other.text)) return ctx.fail(.invalid_connection, role.span, "Duplicate connection endpoint role");
                };
            }
            var occurrences: usize = 0;
            for (endpoints) |other| if (std.mem.eql(u8, other.table.text, endpoint.table.text)) {
                occurrences += 1;
            };
            if (occurrences > 1 and endpoint.role == null)
                return ctx.fail(.invalid_connection, endpoint.span, "Repeated connection endpoints require unique roles");
            const parent = for (tables) |candidate| {
                if (std.mem.eql(u8, candidate.name.text, endpoint.table.text)) break candidate;
            } else return ctx.fail(.invalid_connection, endpoint.table.span, "Unknown connection endpoint table");
            var key_count: usize = 0;
            for (parent.fields) |field| if (field.primary_key) {
                key_count += 1;
            };
            if (key_count == 0 or (parent.connection == null and key_count != 1))
                return ctx.fail(.invalid_connection, endpoint.span, "Generated connection endpoint requires exactly one declared primary key (or a connection's complete key)");
            var names: std.ArrayList(parsed.Token) = .empty;
            const prefix = endpoint.role orelse endpoint.table;
            // A role can equal another endpoint's table name without identifying
            // the same tuple. Group by endpoint slot, not naming prefix.
            const group = if (key_count > 1) try std.fmt.allocPrint(ctx.allocator, "generated:{d}", .{ei}) else null;
            for (parent.fields) |pk| {
                if (!pk.primary_key) continue;
                const name = try keyName(ctx, prefix, pk.name, endpoint.span);
                for (fields.items) |prior| if (std.mem.eql(u8, prior.name.text, name.text))
                    return ctx.fail(.invalid_connection, endpoint.span, "Generated connection key names collide; declare distinct roles/keys");
                var generated: parsed.Field = .{
                    .name = name,
                    .type = .{ .name = endpoint.table, .span = endpoint.table.span },
                    .primary_key = true,
                    .foreign_key = true,
                    .foreign_key_component = if (key_count > 1) pk.name else null,
                    .foreign_key_group = group,
                    .span = marker,
                };
                for (tables[ti].fields) |field| {
                    if (!std.mem.eql(u8, field.name.text, name.text)) continue;
                    if (!field.foreign_key) return ctx.fail(.invalid_connection, field.name.span, "Generated key override must retain its stored foreign-key role");
                    if (!field.primary_key) return ctx.fail(.invalid_connection, field.name.span, "Generated key override must retain its primary-key role");
                    if (field.type.nullable) return ctx.fail(.invalid_connection, field.type.span, "Generated key override must be nonnullable");
                    if (!std.mem.eql(u8, field.type.name.text, endpoint.table.text))
                        return ctx.fail(.invalid_connection, field.type.name.span, "Generated key override must target its exact DSL endpoint table");
                    for (field.directives) |directive| if (directive.kind == .allow_reuse)
                        return ctx.fail(.invalid_connection, directive.span, "Generated key override cannot use #allow reuse");
                    generated = field;
                    generated.foreign_key_component = if (key_count > 1) pk.name else null;
                    generated.foreign_key_group = group;
                }
                try fields.append(ctx.allocator, generated);
                try names.append(ctx.allocator, name);
            }
            endpoint.key_names = try names.toOwnedSlice(ctx.allocator);
        }
        for (tables[ti].fields) |field| {
            const overridden = for (fields.items) |generated| {
                if (std.mem.eql(u8, field.name.text, generated.name.text)) break true;
            } else false;
            if (!overridden) try fields.append(ctx.allocator, field);
        }
        tables[ti].fields = try fields.toOwnedSlice(ctx.allocator);
        tables[ti].connection.?.endpoints = endpoints;
    }
    // Explicit *!pair Connection expands as pair + each target key name.
    // Scalar options/defaults cannot describe a tuple; only #onDelete applies to it.
    var lowered: std.ArrayList(parsed.Field) = .empty;
    for (tables[ti].fields) |field| {
        if (!field.foreign_key or !field.primary_key or field.foreign_key_component != null) {
            try lowered.append(ctx.allocator, field);
            continue;
        }
        const parent = for (tables) |candidate| {
            if (std.mem.eql(u8, candidate.name.text, field.type.name.text)) break candidate;
        } else {
            try lowered.append(ctx.allocator, field);
            continue;
        };
        var key_count: usize = 0;
        for (parent.fields) |pk| if (pk.primary_key) {
            key_count += 1;
        };
        if (parent.connection == null or key_count < 2) {
            try lowered.append(ctx.allocator, field);
            continue;
        }
        if (field.type.nullable) return ctx.fail(.invalid_connection, field.type.span, "Composite connection endpoint must be nonnullable");
        if (field.default != null) return ctx.fail(.invalid_connection, field.span, "Composite connection endpoint cannot have a scalar default");
        for (field.directives) |directive| if (directive.kind != .on_delete)
            return ctx.fail(.invalid_connection, directive.span, "Composite connection endpoint only accepts #onDelete; configure generated components individually");
        for (parent.fields) |pk| {
            if (!pk.primary_key) continue;
            var component = field;
            component.name = try keyName(ctx, field.name, pk.name, field.name.span);
            component.documentation = null;
            component.foreign_key_component = pk.name;
            component.foreign_key_group = field.name.text;
            try lowered.append(ctx.allocator, component);
        }
    }
    tables[ti].fields = try lowered.toOwnedSlice(ctx.allocator);
    heights[ti] = height;
    states[ti] = 2;
}
