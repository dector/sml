//! Table-local namespace shared by explicit UNIQUE and CHECK constraints.
const std = @import("std");
const resolved = @import("model/resolved.zig");
pub const Error = error{ InvalidIdentifier, SqlNameCollision };

/// Each scan visits declarations once, including unnamed constraints and empty
/// columns. next() is amortized constant time per declaration, not per name.
const NameIterator = struct {
    table: resolved.Table,
    phase: enum { table_unique, table_checks, column_unique, column_checks } = .table_unique,
    column_index: usize = 0,
    item_index: usize = 0,

    fn next(self: *NameIterator) ?[]const u8 {
        while (true) {
            switch (self.phase) {
                .table_unique => {
                    while (self.item_index < self.table.unique_constraints.len) {
                        const item = self.table.unique_constraints[self.item_index];
                        self.item_index += 1;
                        if (item.name) |name| return name;
                    }
                    self.phase = .table_checks;
                },
                .table_checks => {
                    while (self.item_index < self.table.checks.len) {
                        const item = self.table.checks[self.item_index];
                        self.item_index += 1;
                        if (item.name) |name| return name;
                    }
                    self.phase = .column_unique;
                },
                .column_unique => {
                    if (self.column_index == self.table.columns.len) return null;
                    const column = self.table.columns[self.column_index];
                    while (self.item_index < column.unique_constraints.len) {
                        const item = column.unique_constraints[self.item_index];
                        self.item_index += 1;
                        if (item.name) |name| return name;
                    }
                    self.phase = .column_checks;
                },
                .column_checks => {
                    const column = self.table.columns[self.column_index];
                    while (self.item_index < column.checks.len) {
                        const item = column.checks[self.item_index];
                        self.item_index += 1;
                        if (item.name) |name| return name;
                    }
                    self.column_index += 1;
                    self.phase = .column_unique;
                },
            }
            self.item_index = 0;
        }
    }
};

/// Allocation-free pairwise validation: O(names * declarations) visits (O(n²)
/// for n named constraints), plus the cost of comparing identifier bytes.
/// Unnamed declarations are traversed once per scan, never once per comparison.
pub fn validate(table: resolved.Table) Error!void {
    var names = NameIterator{ .table = table };
    var n: usize = 0;
    while (names.next()) |name| : (n += 1) {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidIdentifier;
        var prior_names = NameIterator{ .table = table };
        var prior: usize = 0;
        while (prior < n) : (prior += 1) {
            if (std.ascii.eqlIgnoreCase(name, prior_names.next().?)) return error.SqlNameCollision;
        }
    }
}

test "thousands of mixed named constraints retain namespace and identifier validation" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const count = 512;
    const expression = resolved.Expression{ .kind = .{ .boolean = true }, .span = .{ .start = 0, .end = 0 } };
    const uniques = try a.alloc(resolved.UniqueConstraint, count * 2);
    const checks = try a.alloc(resolved.Check, count * 2);
    const column_uniques = try a.alloc(resolved.UniqueConstraint, count * 2);
    const column_checks = try a.alloc(resolved.Check, count * 2);
    for (0..count) |i| {
        uniques[2 * i] = .{};
        uniques[2 * i + 1] = .{ .name = try std.fmt.allocPrint(a, "table_unique_{d}", .{i}) };
        checks[2 * i] = .{ .expression = expression };
        checks[2 * i + 1] = .{ .expression = expression, .name = try std.fmt.allocPrint(a, "table_check_{d}", .{i}) };
        column_uniques[2 * i] = .{};
        column_uniques[2 * i + 1] = .{ .name = try std.fmt.allocPrint(a, "column_unique_{d}", .{i}) };
        column_checks[2 * i] = .{ .expression = expression };
        column_checks[2 * i + 1] = .{ .expression = expression, .name = try std.fmt.allocPrint(a, "column_check_{d}", .{i}) };
    }
    const table = resolved.Table{
        .dsl_name = "Mixed",
        .sql_name = "mixed",
        .unique_constraints = uniques,
        .checks = checks,
        .columns = &.{
            .{ .dsl_name = "empty", .sql_name = "empty", .type = .integer },
            .{ .dsl_name = "first", .sql_name = "first", .type = .integer, .unique_constraints = column_uniques[0..count], .checks = column_checks[0..count] },
            .{ .dsl_name = "gap", .sql_name = "gap", .type = .integer },
            .{ .dsl_name = "last", .sql_name = "last", .type = .integer, .unique_constraints = column_uniques[count..], .checks = column_checks[count..] },
        },
    };
    try validate(table);
    // A final column CHECK collides with each of the four namespace sources.
    for ([_][]const u8{ "TABLE_UNIQUE_0", "TABLE_CHECK_0", "COLUMN_UNIQUE_0", "COLUMN_CHECK_0" }) |name| {
        column_checks[column_checks.len - 1].name = name;
        try std.testing.expectError(error.SqlNameCollision, validate(table));
    }
    for ([_][]const u8{ "", "bad\x00name", "\xff" }) |name| {
        column_checks[column_checks.len - 1].name = name;
        try std.testing.expectError(error.InvalidIdentifier, validate(table));
    }
    // Validate the current identifier before checking its collision, and keep
    // iteration order: a prior collision still wins over a later invalid name.
    uniques[1].name = "\xff";
    uniques[3].name = "\xff";
    try std.testing.expectError(error.InvalidIdentifier, validate(table));
    uniques[1].name = "same";
    uniques[3].name = "SAME";
    try std.testing.expectError(error.SqlNameCollision, validate(table));
}
