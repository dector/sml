//! Shared named-connection invariants. No role-to-field naming convention exists.
const std = @import("std");
const resolved = @import("model/resolved.zig");

pub fn matches(column: resolved.Column, table: resolved.Table) bool {
    const fk = column.foreign_key orelse return false;
    return std.ascii.eqlIgnoreCase(fk.target_table_sql_name, table.sql_name);
}

pub fn validate(schema: resolved.Schema, table: resolved.Table) error{InvalidConnection}!void {
    const connection = table.connection orelse return;
    const endpoints = connection.endpoints;
    if (endpoints.len < 2) return error.InvalidConnection;
    if (connection.unnamed) {
        if (endpoints.len != 2 or endpoints[0].role != null or endpoints[1].role != null or
            endpoints[0].table_index >= schema.tables.len or endpoints[1].table_index >= schema.tables.len)
            return error.InvalidConnection;
        const a = schema.tables[endpoints[0].table_index].dsl_name;
        const b = schema.tables[endpoints[1].table_index].dsl_name;
        if (std.mem.order(u8, a, b) != .lt) return error.InvalidConnection;
        const key = try @import("connection_identity.zig").canonicalKey(a, b);
        const identity = connection.identity orelse return error.InvalidConnection;
        if (!identity.eql(key)) return error.InvalidConnection;
        var identities: usize = 0;
        for (schema.tables) |other| {
            const candidate = other.connection orelse continue;
            if (!candidate.unnamed) continue;
            if (candidate.endpoints.len != 2 or candidate.endpoints[0].table_index >= schema.tables.len or candidate.endpoints[1].table_index >= schema.tables.len)
                return error.InvalidConnection;
            const other_key = try @import("connection_identity.zig").canonicalKey(
                schema.tables[candidate.endpoints[0].table_index].dsl_name,
                schema.tables[candidate.endpoints[1].table_index].dsl_name,
            );
            if (key.eql(other_key)) identities += 1;
        }
        if (identities != 1) return error.InvalidConnection;
    } else if (connection.identity != null) return error.InvalidConnection;
    var keys: usize = 0;
    for (table.columns) |column| {
        if (column.primary_key == .none) continue;
        keys += 1;
        if (column.primary_key != .standard or column.nullable or column.foreign_key == null) return error.InvalidConnection;
        const found = for (endpoints) |endpoint| {
            if (endpoint.table_index >= schema.tables.len) return error.InvalidConnection;
            if (matches(column, schema.tables[endpoint.table_index])) break true;
        } else false;
        if (!found) return error.InvalidConnection;
    }
    if (keys != endpoints.len) return error.InvalidConnection;
    for (endpoints, 0..) |endpoint, i| {
        if (endpoint.table_index >= schema.tables.len) return error.InvalidConnection;
        const target = schema.tables[endpoint.table_index];
        if (target.connection != null) return error.InvalidConnection;
        if (endpoint.role) |role| {
            if (role.len == 0 or std.mem.indexOfScalar(u8, role, 0) != null) return error.InvalidConnection;
            for (endpoints[0..i]) |prior| if (prior.role) |other| {
                if (std.mem.eql(u8, role, other)) return error.InvalidConnection;
            };
        }
        var occurrences: usize = 0;
        for (endpoints) |other| {
            if (other.table_index == endpoint.table_index) {
                occurrences += 1;
                if (other.role == null and endpoint.role != null) return error.InvalidConnection;
            }
        }
        if (occurrences > 1 and endpoint.role == null) return error.InvalidConnection;
        var parent_key: ?resolved.Column = null;
        for (target.columns) |column| if (column.primary_key != .none) {
            if (parent_key != null or column.nullable or column.type == .boolean) return error.InvalidConnection;
            parent_key = column;
        };
        const pk = parent_key orelse return error.InvalidConnection;
        var matching_keys: usize = 0;
        for (table.columns) |column| {
            if (column.primary_key == .none or !matches(column, target)) continue;
            matching_keys += 1;
            const fk = column.foreign_key.?;
            if (!std.ascii.eqlIgnoreCase(fk.target_column_sql_name, pk.sql_name) or column.type != pk.type or
                (fk.delete_action == .set_null and !column.nullable) or column.enum_values.len != pk.enum_values.len)
                return error.InvalidConnection;
            for (pk.enum_values) |value| {
                if (!@import("enumeration.zig").contains(column.enum_values, value)) return error.InvalidConnection;
            }
        }
        if (matching_keys != occurrences) return error.InvalidConnection;
        if (endpoint.column_index) |ci| {
            if (ci >= table.columns.len) return error.InvalidConnection;
            const column = table.columns[ci];
            if (column.primary_key == .none or !matches(column, target)) return error.InvalidConnection;
            for (endpoints[0..i]) |prior| if (prior.column_index == ci) return error.InvalidConnection;
        }
    }
}
