//! Shared relationship mapping proof. Destination inference belongs to the resolver only.
const std = @import("std");
const resolved = @import("model/resolved.zig");
const connection = @import("connection_validation.zig");

pub fn references(column: resolved.Column, target: resolved.Table) bool {
    const fk = column.foreign_key orelse return false;
    var key: ?resolved.Column = null;
    for (target.columns) |c| if (c.primary_key != .none) {
        if (key != null or c.nullable) return false;
        key = c;
    };
    const pk = key orelse return false;
    return std.ascii.eqlIgnoreCase(fk.target_table_sql_name, target.sql_name) and
        std.ascii.eqlIgnoreCase(fk.target_column_sql_name, pk.sql_name);
}

pub fn endpoint(schema: resolved.Schema, source: resolved.Table, ci: usize, target: usize) bool {
    const metadata = source.connection orelse return false;
    if (ci >= source.columns.len or target >= schema.tables.len) return false;
    const column = source.columns[ci];
    if (column.primary_key == .none or !references(column, schema.tables[target])) return false;
    // Repeated header roles deliberately do not assign names to authored keys.
    for (metadata.endpoints) |e| if (e.table_index == target) return true;
    return false;
}

pub fn validate(schema: resolved.Schema, r: resolved.Relationship) error{InvalidRelationship}!void {
    if (r.owner_table_index >= schema.tables.len or r.source_table_index >= schema.tables.len or
        r.target_table_index >= schema.tables.len) return error.InvalidRelationship;
    const source = schema.tables[r.source_table_index];
    if (r.backing_column_index >= source.columns.len or
        !references(source.columns[r.backing_column_index], schema.tables[r.owner_table_index])) return error.InvalidRelationship;
    if (source.connection != null) {
        connection.validate(schema, source) catch return error.InvalidRelationship;
        const dest = r.destination_column_index orelse return error.InvalidRelationship;
        if (dest == r.backing_column_index or
            !endpoint(schema, source, r.backing_column_index, r.owner_table_index) or
            !endpoint(schema, source, dest, r.target_table_index)) return error.InvalidRelationship;
    } else if (r.source_table_index != r.target_table_index or r.destination_column_index != null) {
        return error.InvalidRelationship;
    }
    if (r.cardinality == .optional_one and !@import("unique.zig").singleColumn(source, r.backing_column_index))
        return error.InvalidRelationship;
}
