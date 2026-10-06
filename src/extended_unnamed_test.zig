const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");
const identity = @import("connection_identity.zig");
const fixture = @embedFile("testdata/parser/extended_unnamed.pzl");

fn resolve(allocator: std.mem.Allocator, source: []const u8) !resolver.OwnedSchema {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    if (result == .diagnostic) {
        std.debug.print("{s}\n", .{result.diagnostic.message});
        return error.UnexpectedDiagnostic;
    }
    return result.schema;
}

fn pipeline(allocator: std.mem.Allocator) !void {
    var owned = blk: {
        const source = try allocator.dupe(u8, fixture);
        defer allocator.free(source);
        break :blk try resolve(allocator, source);
    };
    defer owned.deinit();
    const schema = owned.schema;
    try std.testing.expectEqualStrings("A__n__A", schema.tables[1].dsl_name);
    try std.testing.expectEqualStrings("A__n__A__n__B", schema.tables[2].dsl_name);
    try std.testing.expect(!schema.tables[1].connection.?.identity.?.eql(schema.tables[2].connection.?.identity.?));
    try std.testing.expectEqualStrings("left", schema.tables[1].connection.?.endpoints[0].role.?);
    try std.testing.expectEqualStrings("leftKey", schema.tables[1].columns[0].dsl_name);
    try std.testing.expectEqual(@as(usize, 1), schema.relationships[0].source_table_index);
    try std.testing.expectEqual(@as(usize, 1), schema.relationships[0].destination_column_index.?);
    for (schema.tables[0..3]) |table| for (table.connection.?.endpoints, 0..) |endpoint, i| {
        try std.testing.expectEqual(i, endpoint.column_index.?);
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    emitter.emit(schema, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/extended_unnamed.expect.sql"), out.written());
}

test "extended unnamed ownership multiset override slots and self shorthand" {
    try pipeline(std.testing.allocator);
}

test "extended unnamed allocation failures" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "extended reversed headers are identical and explicit keys keep authored order" {
    const parents = "A {\n!key int\n}\nB {\n!key int\n}\n";
    var baseline: ?[]u8 = null;
    defer if (baseline) |sql| std.testing.allocator.free(sql);
    for ([_][]const u8{
        "~(right A, B, left A) {\n~~\n*!rightKey A {\n#name `custom`\n}\n}\n",
        "~(left A, right A, B) {\n*!rightKey A {\n#name `custom`\n}\n~~\n}\n",
    }) |header| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ header, parents });
        defer std.testing.allocator.free(source);
        var owned = try resolve(std.testing.allocator, source);
        defer owned.deinit();
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try emitter.emit(owned.schema, &out.writer);
        if (baseline) |sql| try std.testing.expectEqualStrings(sql, out.written()) else baseline = try std.testing.allocator.dupe(u8, out.written());
    }
    var owned = try resolve(std.testing.allocator, "~(right A, B, left A) {\n*!b B\n*!r A\n*!l A\n}\nA {\n!key int\n}\nB {\n!key int\n}\n");
    defer owned.deinit();
    const table = owned.schema.tables[0];
    try std.testing.expectEqualStrings("b", table.columns[0].dsl_name);
    try std.testing.expectEqualStrings("r", table.columns[1].dsl_name);
    try std.testing.expectEqualStrings("l", table.columns[2].dsl_name);
    try std.testing.expectEqualStrings("left", table.connection.?.endpoints[0].role.?);
    try std.testing.expect(table.connection.?.endpoints[0].column_index == null);
    try std.testing.expectEqual(@as(usize, 0), table.connection.?.endpoints[2].column_index.?);
}

test "roles excluded from duplicate identity and repeated tables require roles" {
    const cases = [_][2][]const u8{
        .{ "~(x A, y A) {\n~~\n}\n~(p A, q A) {\n#name `different`\n~~\n}\nA {\n!id int\n}\n", "Duplicate unnamed" },
        .{ "~(A, x A) {\n~~\n}\nA {\n!id int\n}\n", "unique roles" },
        .{ "~(x A, x A) {\n~~\n}\nA {\n!id int\n}\n", "Duplicate connection endpoint role" },
        .{ "~(A, A) {\n*!x A\n*!y A\n}\nA {\n!id int\n}\n", "unique roles" },
        .{ "A {\n!id int\n~as A[] @.xId\n}\n", "explicit unnamed" },
        .{ "~(x A, y A, z A) {\n~~\n}\nA {\n!id int\n~as A[] @.xId\n}\n", "explicit unnamed" },
        .{ "~(x A, y A, z A) {\n~~\n}\nA {\n!id int\n~as A[] @A__n__A__n__A.xId\n}\n", "Ambiguous" },
    };
    for (cases) |case| {
        var syntax = try parser.parse(std.testing.allocator, case[0]);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, case[1]) != null);
    }
}

test "multi endpoints use explicit hints but shorthand never uses pair containment" {
    var owned = try resolve(std.testing.allocator, "~(x A, y A, z A) {\n~~\n}\nA {\n!id int\n~as A[] @A__n__A__n__A.xId <<zId\n}\n");
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 2), owned.schema.relationships[0].destination_column_index.?);
    var pair = try resolve(std.testing.allocator, "~(A, B, C) {\n~~\n}\nA {\n!id int\n~bs B[] @.aId\n}\nB {\n!id int\n}\nC {\n!id int\n}\n");
    defer pair.deinit();
    try std.testing.expectEqual(@as(usize, 5), pair.schema.tables.len);
    try std.testing.expectEqualStrings("A__n__B", pair.schema.tables[pair.schema.relationships[0].source_table_index].dsl_name);
}

test "exact shorthand reuses explicit role and self pairs without guessing authored bindings" {
    var owned = try resolve(std.testing.allocator, "A {\n!id int\n~bs B[] @.owner <<dest\n~as A[] @.from <<to\n}\nB {\n!id int\n}\n~(reader A, publication B) {\n*!dest B\n*!owner A\n}\n~(right A, left A) {\n*!to A\n*!from A\n}\n");
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 4), owned.schema.tables.len);
    try std.testing.expectEqual(@as(usize, 2), owned.schema.relationships[0].source_table_index);
    try std.testing.expectEqual(@as(usize, 3), owned.schema.relationships[1].source_table_index);
    try std.testing.expectEqual(@as(usize, 0), owned.schema.relationships[1].destination_column_index.?);
    for (owned.schema.tables[3].connection.?.endpoints) |endpoint| try std.testing.expect(endpoint.column_index == null);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitter.emit(owned.schema, &out.writer);
}

test "extended inherited date enum and non-id DSL key names" {
    var owned = try resolve(std.testing.allocator, "~(Alias, State, Clock) {\n~~\n}\nAlias {\n*!local_key State\n}\nState {\n!status enum {\n#of ready, done\n}\n}\nClock {\n!calendar_day date\n#name `Calendar`\n}\n");
    defer owned.deinit();
    const columns = owned.schema.tables[0].columns;
    try std.testing.expectEqualStrings("aliasLocalKey", columns[0].dsl_name);
    try std.testing.expectEqualStrings("clockCalendarDay", columns[1].dsl_name);
    try std.testing.expectEqualStrings("stateStatus", columns[2].dsl_name);
    try std.testing.expectEqual(resolved.StorageType.enumeration, columns[0].type);
    try std.testing.expectEqual(resolved.StorageType.date, columns[1].type);
    try std.testing.expectEqual(@as(usize, 2), columns[0].enum_values.len);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitter.emit(owned.schema, &out.writer);
}

test "extended invalid public multiplicity ordering binding and collisions emit nothing" {
    var owned = try resolve(std.testing.allocator, fixture);
    defer owned.deinit();
    const tables = @constCast(owned.schema.tables);
    const original = tables[2].connection.?;
    const endpoints = @constCast(original.endpoints);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    tables[2].connection.?.identity = tables[1].connection.?.identity;
    try std.testing.expectError(error.InvalidConnection, emitter.emit(owned.schema, &out.writer));
    tables[2].connection = original;
    std.mem.swap(resolved.Endpoint, &endpoints[0], &endpoints[1]);
    try std.testing.expectError(error.InvalidConnection, emitter.emit(owned.schema, &out.writer));
    std.mem.swap(resolved.Endpoint, &endpoints[0], &endpoints[1]);
    endpoints[1].column_index = 0;
    try std.testing.expectError(error.InvalidConnection, emitter.emit(owned.schema, &out.writer));
    endpoints[1].column_index = 1;
    const name = tables[1].sql_name;
    tables[1].sql_name = tables[0].sql_name;
    try std.testing.expectError(error.SqlNameCollision, emitter.emit(owned.schema, &out.writer));
    tables[1].sql_name = name;
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "identity comparison retains repeat multiplicity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pair = try identity.canonicalKey(arena.allocator(), &.{ "A", "A" });
    const triple = try identity.canonicalKey(arena.allocator(), &.{ "A", "A", "A" });
    try std.testing.expect(!pair.eql(triple));
    try std.testing.expectEqual(std.math.Order.lt, pair.order(triple));
}
