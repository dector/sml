//! Shared named-connection invariants. No role-to-field naming convention exists.
const std = @import("std");
const resolved = @import("model/resolved.zig");

pub fn matches(column: resolved.Column, table: resolved.Table) bool {
    const fk = column.foreign_key orelse return false;
    return std.ascii.eqlIgnoreCase(fk.target_table_sql_name, table.sql_name);
}

fn indices(endpoint: resolved.Endpoint) []const usize {
    return endpoint.column_indices;
}

fn isComposite(fk: resolved.ForeignKey) bool {
    return fk.composite;
}

fn bindingLen(endpoint: resolved.Endpoint) usize {
    const columns = indices(endpoint);
    return if (columns.len != 0) columns.len else if (endpoint.column_index != null) 1 else 0;
}

fn bindingAt(endpoint: resolved.Endpoint, i: usize) usize {
    const columns = indices(endpoint);
    return if (columns.len != 0) columns[i] else endpoint.column_index.?;
}

fn keyCount(table: resolved.Table) usize {
    var count: usize = 0;
    for (table.columns) |column| if (column.primary_key != .none) {
        count += 1;
    };
    return count;
}

// Every valid dependency tree has at most one leaf per flattened key component
// and at most 256 connection levels. Bound both stack depth and work even for
// forged DAG metadata whose declared keys do not actually cover its leaves.
fn validateGraph(schema: resolved.Schema, table: resolved.Table, depth: usize, budget: *usize) error{InvalidConnection}!void {
    const connection = table.connection orelse return;
    if (depth >= schema.tables.len or depth >= 256 or budget.* == 0) return error.InvalidConnection;
    budget.* -= 1;
    for (connection.endpoints) |endpoint| {
        if (endpoint.table_index >= schema.tables.len) return error.InvalidConnection;
        try validateGraph(schema, schema.tables[endpoint.table_index], depth + 1, budget);
    }
}

fn validateComponent(column: resolved.Column, target: resolved.Table, pk: resolved.Column, composite: bool) error{InvalidConnection}!void {
    const fk = column.foreign_key orelse return error.InvalidConnection;
    if (column.primary_key != .standard or column.nullable or !matches(column, target) or
        isComposite(fk) != composite or !std.ascii.eqlIgnoreCase(fk.target_column_sql_name, pk.sql_name) or
        column.type != pk.type or fk.delete_action == .set_null or column.enum_values.len != pk.enum_values.len)
        return error.InvalidConnection;
    for (pk.enum_values) |value| {
        if (!@import("enumeration.zig").contains(column.enum_values, value)) return error.InvalidConnection;
    }
}

fn validateGroup(table: resolved.Table, target: resolved.Table, columns: []const usize, arity: usize) error{InvalidConnection}!void {
    if (columns.len != arity) return error.InvalidConnection;
    var component: usize = 0;
    var action: ?resolved.DeleteAction = null;
    for (target.columns) |pk| {
        if (pk.primary_key == .none) continue;
        const ci = columns[component];
        if (ci >= table.columns.len) return error.InvalidConnection;
        for (columns[0..component]) |prior| if (prior == ci) return error.InvalidConnection;
        const column = table.columns[ci];
        try validateComponent(column, target, pk, true);
        const current_action = column.foreign_key.?.delete_action;
        if (action) |previous| {
            if (previous != current_action) return error.InvalidConnection;
        }
        action = current_action;
        component += 1;
    }
}

fn validateCompositeKeys(table: resolved.Table, target: resolved.Table, arity: usize, occurrences: usize) error{InvalidConnection}!void {
    var matching_groups: usize = 0;
    for (table.composite_foreign_keys) |group| {
        // Never inspect a component until its index has been checked.
        for (group.columns) |ci| if (ci >= table.columns.len) return error.InvalidConnection;
        var targets_endpoint = false;
        for (group.columns) |ci| {
            if (matches(table.columns[ci], target)) targets_endpoint = true;
        }
        if (!targets_endpoint) continue;
        try validateGroup(table, target, group.columns, arity);
        matching_groups += 1;
    }
    if (matching_groups != occurrences) return error.InvalidConnection;
    // Every local key for this endpoint belongs to exactly one complete group.
    // This also rejects duplicate groups and overlapping groups.
    for (table.columns, 0..) |column, ci| {
        if (column.primary_key == .none or !matches(column, target)) continue;
        var memberships: usize = 0;
        for (table.composite_foreign_keys) |group| {
            for (group.columns) |member| if (member == ci) {
                memberships += 1;
            };
        }
        if (memberships != 1) return error.InvalidConnection;
    }
}

fn validateGroupIndices(table: resolved.Table) error{InvalidConnection}!void {
    for (table.composite_foreign_keys) |group| {
        if (group.columns.len < 2) return error.InvalidConnection;
        for (group.columns, 0..) |ci, i| {
            if (ci >= table.columns.len or std.mem.indexOfScalar(usize, group.columns[0..i], ci) != null)
                return error.InvalidConnection;
        }
    }
}

fn bindingIsGroup(table: resolved.Table, endpoint: resolved.Endpoint) bool {
    for (table.composite_foreign_keys) |group| {
        if (std.mem.eql(usize, group.columns, indices(endpoint))) return true;
    }
    return false;
}

pub fn validate(schema: resolved.Schema, table: resolved.Table) error{InvalidConnection}!void {
    const connection = table.connection orelse return;
    const endpoints = connection.endpoints;
    if (endpoints.len < 2) return error.InvalidConnection;
    var graph_budget = std.math.mul(usize, @max(keyCount(table), 1), 256) catch return error.InvalidConnection;
    try validateGraph(schema, table, 0, &graph_budget);
    try validateGroupIndices(table);
    if (connection.unnamed) {
        const identity = connection.identity orelse return error.InvalidConnection;
        if (identity.endpoints.len != endpoints.len) return error.InvalidConnection;
        for (endpoints, 0..) |endpoint, i| {
            if (endpoint.table_index >= schema.tables.len) return error.InvalidConnection;
            const name = schema.tables[endpoint.table_index].dsl_name;
            if (!std.mem.eql(u8, name, identity.endpoints[i])) return error.InvalidConnection;
            if (i > 0) {
                const order = std.mem.order(u8, identity.endpoints[i - 1], name);
                if (order == .gt) return error.InvalidConnection;
                if (order == .eq and std.mem.order(u8, endpoints[i - 1].role orelse "", endpoint.role orelse "") != .lt)
                    return error.InvalidConnection;
            }
        }
        var identities: usize = 0;
        for (schema.tables) |other| {
            const candidate = other.connection orelse continue;
            if (!candidate.unnamed) continue;
            const other_key = candidate.identity orelse return error.InvalidConnection;
            if (identity.eql(other_key)) identities += 1;
        }
        if (identities != 1) return error.InvalidConnection;
    } else if (connection.identity != null) return error.InvalidConnection;
    var expected_keys: usize = 0;
    for (endpoints) |endpoint| {
        if (endpoint.table_index >= schema.tables.len) return error.InvalidConnection;
        const arity = keyCount(schema.tables[endpoint.table_index]);
        expected_keys = std.math.add(usize, expected_keys, arity) catch return error.InvalidConnection;
    }
    var keys: usize = 0;
    for (table.columns) |column| {
        if (column.primary_key == .none) continue;
        keys += 1;
        if (column.primary_key != .standard or column.nullable or column.foreign_key == null) return error.InvalidConnection;
        const found = for (endpoints) |endpoint| {
            if (matches(column, schema.tables[endpoint.table_index])) break true;
        } else false;
        if (!found) return error.InvalidConnection;
    }
    if (keys != expected_keys) return error.InvalidConnection;
    for (endpoints, 0..) |endpoint, i| {
        const target = schema.tables[endpoint.table_index];
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
        const arity = keyCount(target);
        if (arity == 0 or (arity > 1 and target.connection == null)) return error.InvalidConnection;
        for (target.columns) |pk| {
            if (pk.primary_key != .none and (pk.nullable or pk.type == .boolean)) return error.InvalidConnection;
        }
        var matching_keys: usize = 0;
        for (table.columns) |column| {
            if (column.primary_key == .none or !matches(column, target)) continue;
            matching_keys += 1;
            if (arity == 1) {
                for (target.columns) |pk| {
                    if (pk.primary_key != .none) try validateComponent(column, target, pk, false);
                }
            }
        }
        const expected = std.math.mul(usize, arity, occurrences) catch return error.InvalidConnection;
        if (matching_keys != expected) return error.InvalidConnection;
        if (arity > 1) try validateCompositeKeys(table, target, arity, occurrences);

        const bound = bindingLen(endpoint);
        if (bound == 0) {
            if (occurrences == 1) return error.InvalidConnection;
            continue;
        }
        if (bound != arity) return error.InvalidConnection;
        if (arity > 1) {
            if (endpoint.column_index != null or !bindingIsGroup(table, endpoint)) return error.InvalidConnection;
        } else if (endpoint.column_index) |ci| {
            if (ci != bindingAt(endpoint, 0)) return error.InvalidConnection;
        }
        for (0..bound) |component| {
            const ci = bindingAt(endpoint, component);
            if (ci >= table.columns.len) return error.InvalidConnection;
            const column = table.columns[ci];
            if (column.primary_key != .standard or !matches(column, target)) return error.InvalidConnection;
            for (endpoints[0..i]) |prior| {
                for (0..bindingLen(prior)) |previous| {
                    if (bindingAt(prior, previous) == ci) return error.InvalidConnection;
                }
            }
        }
    }
}

test "connection validation binds complete composite groups and rejects forged metadata" {
    const parent: resolved.Table = .{
        .dsl_name = "A",
        .sql_name = "a",
        .columns = &.{.{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard }},
    };
    const inner: resolved.Table = .{
        .dsl_name = "Inner",
        .sql_name = "inner",
        .connection = .{ .endpoints = &.{
            .{ .table_index = 0, .role = "left", .column_index = 0, .column_indices = &.{0} },
            .{ .table_index = 0, .role = "right", .column_index = 1, .column_indices = &.{1} },
        } },
        .columns = &.{
            .{ .dsl_name = "x", .sql_name = "x", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "a", .target_column_sql_name = "id" } },
            .{ .dsl_name = "y", .sql_name = "y", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "a", .target_column_sql_name = "id" } },
        },
    };
    const x: resolved.Column = .{ .dsl_name = "x", .sql_name = "x", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "inner", .target_column_sql_name = "x", .composite = true } };
    var y = x;
    y.dsl_name = "y";
    y.sql_name = "y";
    y.foreign_key.?.target_column_sql_name = "y";
    const original_columns = [_]resolved.Column{ x, y, x, y };
    const original_endpoints = [_]resolved.Endpoint{
        .{ .table_index = 1, .role = "left", .column_indices = &.{ 0, 1 } },
        .{ .table_index = 1, .role = "right", .column_indices = &.{ 2, 3 } },
    };
    var columns = original_columns;
    var endpoints = original_endpoints;
    var groups = [_]resolved.CompositeForeignKey{ .{ .columns = &.{ 0, 1 } }, .{ .columns = &.{ 2, 3 } } };
    var tables = [_]resolved.Table{ parent, inner, .{
        .dsl_name = "Outer",
        .sql_name = "outer",
        .connection = .{ .endpoints = &endpoints },
        .columns = &columns,
        .composite_foreign_keys = &groups,
    } };
    const schema: resolved.Schema = .{ .tables = &tables };
    try validate(schema, tables[1]);
    try validate(schema, tables[2]);
    // Repeated explicit endpoints may remain deliberately unbound.
    endpoints[0].column_indices = &.{};
    endpoints[1].column_indices = &.{};
    try validate(schema, tables[2]);
    for (0..11) |case| {
        columns = original_columns;
        endpoints = original_endpoints;
        groups = .{ .{ .columns = &.{ 0, 1 } }, .{ .columns = &.{ 2, 3 } } };
        switch (case) {
            0 => endpoints[0].column_indices = &.{ 0, 3 }, // Cannot mix groups.
            1 => endpoints[1].column_indices = &.{ 0, 1 }, // Cannot share bindings.
            2 => groups[0].columns = &.{ 1, 0 }, // Target PK written order.
            3 => groups[0].columns = &.{ 0, 99 },
            4 => groups[0].columns = &.{0},
            5 => groups[1].columns = &.{ 0, 1 },
            6 => columns[0].foreign_key.?.composite = false,
            7 => columns[0].foreign_key.?.delete_action = .cascade,
            8 => endpoints[0].column_index = 0,
            9 => endpoints[0].table_index = 2, // Self-cycle.
            10 => endpoints[0].column_indices = &.{ 0, 99 },
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidConnection, validate(schema, tables[2]));
    }
    endpoints = original_endpoints;
    tables[1].connection.?.endpoints = &.{ .{ .table_index = 2 }, .{ .table_index = 0 } };
    try std.testing.expectError(error.InvalidConnection, validate(schema, tables[2]));
}
