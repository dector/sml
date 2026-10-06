const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

fn valid(allocator: std.mem.Allocator) !void {
    const source = "~C(left A, right A, B) {\n*!z B\n*!arbitrary A\npayload str\n*!other A\n*extra B\n}\nA {\n!id int\n}\nB {\n*!id A(7)\n}\n";
    var syntax = try parser.parse(allocator, source);
    defer syntax.schema.deinit();
    try std.testing.expect(syntax == .schema);
    var result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    const endpoints = schema.tables[0].connection.?.endpoints;
    try std.testing.expect(endpoints[0].column_index == null);
    try std.testing.expect(endpoints[1].column_index == null);
    try std.testing.expectEqualStrings("left", endpoints[0].role.?);
    try std.testing.expectEqual(@as(usize, 0), endpoints[2].column_index.?);
    try std.testing.expectEqual(@as(usize, 1), endpoints[0].table_index);
    var buffer: [8192]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    try emitter.emit(schema, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "PRIMARY KEY (\"z\", \"arbitrary\", \"other\")") != null);
    try std.testing.expectEqual(resolved.StorageType.integer, schema.tables[0].columns[0].type);
}

test "named connection keys preserve explicit order and self roles stay unbound" {
    try valid(std.testing.allocator);
}
test "named connection ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, valid, .{});
}

test "invalid connection endpoint and explicit key multisets" {
    const bodies = [_][]const u8{
        "~C(A, B) {}\n",
        "~C(A, B) {\n*!a A\n}\n",
        "~C(A, B) {\n*!a A\n*!b B\n!extra int\n}\n",
        "~C(A, B) {\n*!a A\n*!wrong D\n}\n",
        "~C(A, A) {\n*!x A\n*!y A\n}\n",
        "~C(x A, A) {\n*!x A\n*!y A\n}\n",
        "~C(x A, x B) {\n*!x A\n*!y B\n}\n",
        "~C(x A, x A) {\n*!x A\n*!y A\n}\n",
        "~C(A, Missing) {\n*!a A\n*!b B\n}\n",
    };
    for (bodies) |body| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ body, "A {\n!id int\n}\nB {\n!id str\n}\nD {\n!id int\n}\n" });
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(resolver.Category.invalid_connection, result.diagnostic.category);
    }
    const sources = [_][]const u8{
        "A {}\nB {\n!id int\n}\n~C(A, B) {\n*!a A\n*!b B\n}\n",
        "A {\n!x int\n!y int\n}\nB {\n!id int\n}\n~C(A, B) {\n*!a A\n*!b B\n}\n",
        "A {\n!id int\n}\n~Inner(A, A) {\n*!a A\n*!b A\n}\n~Outer(A, Inner) {}\n",
    };
    for (sources) |source| {
        var syntax = try parser.parse(std.testing.allocator, source);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
    }
}

test "emitter rejects forged connection metadata before any output" {
    const parent: resolved.Table = .{ .dsl_name = "A", .sql_name = "a", .columns = &.{.{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard }} };
    const key: resolved.Column = .{ .dsl_name = "x", .sql_name = "x", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "a", .target_column_sql_name = "id" } };
    const endpoint: resolved.Endpoint = .{ .table_index = 0, .role = "left" };
    var endpoints = [_]resolved.Endpoint{ endpoint, .{ .table_index = 0, .role = "right" } };
    var columns = [_]resolved.Column{ key, key };
    columns[1].dsl_name = "y";
    columns[1].sql_name = "y";
    var tables = [_]resolved.Table{ parent, .{ .dsl_name = "C", .sql_name = "c", .connection = .{ .endpoints = &endpoints }, .columns = &columns } };
    const schema: resolved.Schema = .{ .tables = &tables };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(schema, &output.writer);
    for (0..7) |case| {
        endpoints = .{ endpoint, .{ .table_index = 0, .role = "right" } };
        columns[0] = key;
        switch (case) {
            0 => endpoints[0].table_index = 99,
            1 => endpoints[1].role = "left",
            2 => endpoints[0].role = null,
            3 => endpoints[0].column_index = 99,
            4 => {
                endpoints[0].column_index = 0;
                endpoints[1].column_index = 0;
            },
            5 => columns[0].type = .text,
            6 => columns[0].primary_key = .allow_reuse,
            else => unreachable,
        }
        output.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidConnection, emitter.emit(schema, &output.writer));
        try std.testing.expectEqual(@as(usize, 0), output.written().len);
    }
}
