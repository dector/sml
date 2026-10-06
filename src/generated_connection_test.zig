const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const source = @embedFile("testdata/parser/generated_connections.pzl");
const expected = @embedFile("testdata/parser/generated_connections.expect.sql");

fn pipeline(allocator: std.mem.Allocator) !void {
    var result = blk: {
        const text = try allocator.dupe(u8, source);
        defer allocator.free(text);
        var syntax = try parser.parse(allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const original = syntax.schema.schema.tables[0];
        try std.testing.expectEqual(@as(usize, 2), original.fields.len);
        const marker = original.connection.?.generated_keys_span.?;
        try std.testing.expectEqualStrings("~~", text[marker.start..marker.end]);
        const semantic = try resolver.resolve(allocator, syntax.schema.schema);
        try std.testing.expectEqual(@as(usize, 2), syntax.schema.schema.tables[0].fields.len);
        try std.testing.expectEqualStrings("amount", syntax.schema.schema.tables[0].fields[0].name.text);
        break :blk semantic;
    };
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    const names = [_][]const u8{ "writerAccountKey", "snakeNameAccountKey" };
    for (schema.tables[0].columns[0..2], names, 0..) |column, name, ci| {
        try std.testing.expectEqualStrings(name, column.dsl_name);
        try std.testing.expectEqual(ci, schema.tables[0].connection.?.endpoints[ci].column_index.?);
        try std.testing.expect(!column.nullable and column.default == null);
    }
    try std.testing.expectEqualStrings("Actual Key", schema.tables[0].columns[0].foreign_key.?.target_column_sql_name);
    for (schema.tables[1].connection.?.endpoints, 0..) |endpoint, ci| try std.testing.expectEqual(ci, endpoint.column_index.?);
    try std.testing.expectEqual(.integer, schema.tables[2].columns[2].type); // FK PK chain
    try std.testing.expectEqual(@as(usize, 1), schema.relationships.len);
    try std.testing.expectEqual(@as(usize, 0), schema.relationships[0].backing_column_index);
    try std.testing.expectEqualStrings("Generated pairs use header order even when the marker is last.", schema.tables[0].documentation.?.text);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    emitter.emit(schema, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(expected, out.written());
}

test "generated connection pipeline owns fields binds self roles and preserves source" {
    try pipeline(std.testing.allocator);
}
test "generated connection full pipeline allocation failures" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}
test "generated connections emit identical SQL to written keys" {
    var syntax = try parser.parse(std.testing.allocator, @embedFile("testdata/parser/generated_connections_explicit.pzl"));
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitter.emit(result.schema.schema, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "generated names preserve humps remove separators and lowercase only initial" {
    const text = "~C(URL, _foo, Snake_Name) {\n~~\n}\nURL {\n!accountKey int\n}\n_foo {\n!_key int\n}\nSnake_Name {\n!account_key int\n}\n";
    var syntax = try parser.parse(std.testing.allocator, text);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    for (result.schema.schema.tables[0].columns, [_][]const u8{ "uRLAccountKey", "fooKey", "snakeNameAccountKey" }) |column, name| try std.testing.expectEqualStrings(name, column.dsl_name);
}

test "generated endpoint and override diagnostics retain real spans" {
    const Case = struct { body: []const u8, parents: []const u8 = "A {\n!id int\n}\nB {\n!id str\n}\n", category: resolver.Category = .invalid_connection, fragment: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .body = "~C(A, B) {\n~~\n!aId int\n}\n", .fragment = "aId", .message = "foreign-key role" },
        .{ .body = "~C(A, B) {\n~~\n*aId A\n}\n", .fragment = "aId", .message = "primary-key role" },
        .{ .body = "~C(A, B) {\n~~\n*!aId A?\n}\n", .fragment = "A?", .message = "nonnullable" },
        .{ .body = "~C(A, B) {\n~~\n*!aId B\n}\n", .fragment = "B", .message = "exact DSL endpoint" },
        .{ .body = "~C(A, B) {\n~~\n*!aId int\n}\n", .fragment = "int", .message = "exact DSL endpoint" },
        .{ .body = "~C(A, B) {\n~~\n*!aId a\n}\n", .fragment = "a", .message = "exact DSL endpoint" },
        .{ .body = "~C(A, B) {\n~~\n*!aId A {\n#allow reuse\n}\n}\n", .fragment = "#allow reuse", .message = "cannot use" },
        .{ .body = "~C(A, B) {\n*!aId A {\n#name `first`\n}\n~~\n*!aId A {\n#name `second`\n}\n}\n", .category = .duplicate_dsl_name, .fragment = "aId", .message = "duplicate DSL field" },
        .{ .body = "~C(A, B) {\n~~\n*!extra A\n}\n", .fragment = "~C(A, B)", .message = "Connection requires" },
        .{ .body = "~C(A, B) {\nx int\n~~\nx int\n}\n", .category = .duplicate_dsl_name, .fragment = "x", .message = "duplicate DSL" },
        .{ .body = "~C(Role A, role B) {\n~~\n}\n", .parents = "A {\n!id int\n}\nB {\n!id int\n}\n", .fragment = "role B", .message = "names collide" },
        .{ .body = "~C(A, A) {\n~~\n}\n", .fragment = "A", .message = "unique roles" },
        .{ .body = "~C(x A, x B) {\n~~\n}\n", .fragment = "x", .message = "Duplicate" },
        .{ .body = "~C(Missing, B) {\n~~\n}\n", .fragment = "Missing", .message = "Unknown" },
        .{ .body = "~C(int, B) {\n~~\n}\n", .fragment = "int", .message = "Unknown" },
        .{ .body = "~C(A, B) {\n~~\n}\n", .parents = "A {}\nB {\n!id int\n}\n", .fragment = "A", .message = "exactly one" },
        .{ .body = "~C(A, B) {\n~~\n}\n", .parents = "A {\n!x int\n!y int\n}\nB {\n!id int\n}\n", .fragment = "A", .message = "exactly one" },
        .{ .body = "~C(A, B) {\n~~\n}\n", .parents = "A {\n!__ int\n}\nB {\n!id int\n}\n", .fragment = "A", .message = "unrepresentable" },
        .{ .body = "~C(__ A, B) {\n~~\n}\n", .fragment = "__ A", .message = "unrepresentable" },
        .{ .body = "~C(Inner, B) {\n~~\n}\n", .parents = "A {\n!id int\n}\nB {\n!id int\n}\n~Inner(A, B) {\n~~\n}\n", .category = .unsupported_feature, .fragment = "Inner", .message = "Nested" },
    };
    for (cases) |case| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ case.body, case.parents });
        defer std.testing.allocator.free(text);
        var syntax = try parser.parse(std.testing.allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        const d = result.diagnostic;
        try std.testing.expectEqual(case.category, d.category);
        try std.testing.expectEqualStrings(case.fragment, text[d.span.start..d.span.end]);
        try std.testing.expect(std.mem.indexOf(u8, d.message, case.message) != null);
    }
}
