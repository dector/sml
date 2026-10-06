//! Resolver-owned expansion. Source fields/docs stay untouched; generated keys
//! precede all explicit fields in header order, regardless of the marker slot.
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
        if (table.connection) |connection| if (connection.generated_keys_span != null) break true;
    } else false;
    if (!needed) return source;
    const tables = try ctx.allocator.dupe(parsed.Table, source.tables);
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
            for (table.fields) |field| if (std.mem.eql(u8, field.name.text, text))
                return ctx.fail(.unsupported_feature, field.name.span, "Explicit generated-key overrides are not yet supported");
            fields[ei] = .{ .name = .{ .text = text, .span = endpoint.span }, .type = .{ .name = endpoint.table, .span = endpoint.table.span }, .primary_key = true, .foreign_key = true, .span = marker };
        }
        @memcpy(fields[connection.endpoints.len..], table.fields);
        table.fields = fields;
    }
    return .{ .tables = tables };
}
