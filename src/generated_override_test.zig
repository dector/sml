const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const fixture = @embedFile("testdata/parser/generated_overrides.sml");

fn pipeline(allocator: std.mem.Allocator) !void {
    var result = blk: {
        const text = try allocator.dupe(u8, fixture);
        defer allocator.free(text);
        var syntax = try parser.parse(allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const before = syntax.schema.schema.tables[0].fields;
        const semantic = try resolver.resolve(allocator, syntax.schema.schema);
        try std.testing.expectEqual(before.ptr, syntax.schema.schema.tables[0].fields.ptr);
        try std.testing.expectEqual(@as(usize, 4), before.len);
        try std.testing.expectEqualStrings("amount", before[0].name.text);
        try std.testing.expectEqualStrings("authorId", before[1].name.text);
        try std.testing.expectEqual(@as(usize, 3), before[1].directives.len);
        break :blk semantic;
    };
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    for (schema.tables[0].columns, [_][]const u8{ "authorId", "stateCode", "amount", "note" }) |column, name|
        try std.testing.expectEqualStrings(name, column.dsl_name);
    try std.testing.expectEqualStrings("The writer override keeps its own docs.", schema.tables[0].columns[0].documentation.?.text);
    try std.testing.expectEqual(@as(usize, 1), schema.tables[0].columns[0].checks.len);
    try std.testing.expectEqual(@as(usize, 1), schema.tables[0].columns[1].unique_constraints.len);
    for (schema.tables[1].connection.?.endpoints, 0..) |endpoint, ci|
        try std.testing.expectEqual(ci, endpoint.column_index.?);
    for (schema.tables[1].columns, [_][]const u8{ "leftId", "rightId", "contextId", "label" }) |column, name|
        try std.testing.expectEqualStrings(name, column.dsl_name);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    emitter.emit(schema, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/generated_overrides.expect.sql"), out.written());
}

test "override marker position does not affect generated slots or SQL" {
    const variants = [_][]const u8{
        "~C(A, B) {\n~~\n*!bId B\nx int(2)\n*!aId A {\n#name `custom`\n}\n}\n",
        "~C(A, B) {\n*!bId B\nx int(2)\n*!aId A {\n#name `custom`\n}\n~~\n}\n",
        "~C(A, B) {\n*!aId A {\n#name `custom`\n}\n*!bId B\nx int(2)\n}\n",
    };
    var baseline: ?[]u8 = null;
    defer if (baseline) |sql| std.testing.allocator.free(sql);
    for (variants) |body| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ body, "A {\n!id int\n}\nB {\n!id int\n}\n" });
        defer std.testing.allocator.free(text);
        var syntax = try parser.parse(std.testing.allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .schema);
        defer result.schema.deinit();
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try emitter.emit(result.schema.schema, &out.writer);
        if (baseline) |sql| {
            try std.testing.expectEqualStrings(sql, out.written());
        } else baseline = try std.testing.allocator.dupe(u8, out.written());
    }
}

test "generated overrides preserve metadata source ownership order and SQL" {
    try pipeline(std.testing.allocator);
}
test "generated multi and self override pipeline allocation failures" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "generated overrides use ordinary defaults and SQL collision validation" {
    const Case = struct { body: []const u8, category: resolver.Category };
    for ([_]Case{
        .{ .body = "*!aId A('bad')", .category = .invalid_default },
        .{ .body = "*!bCode B(missing)", .category = .invalid_default },
        .{ .body = "*!aId A {\n#name `b_code`\n}", .category = .sql_name_collision },
        .{ .body = "*!aId A {\n#name `custom`\n}\n#index aId {\n#name `C`\n}", .category = .sql_name_collision },
    }) |case| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ "~C(A, B) {\n~~\n", case.body, "\n}\nA {\n!id int\n}\nB {\n!code enum {\n#of ready, done\n}\n}\n" });
        defer std.testing.allocator.free(text);
        var syntax = try parser.parse(std.testing.allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(case.category, result.diagnostic.category);
    }
}
