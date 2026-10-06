const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/foreign_key_indexes.sml"));
    defer allocator.free(source);
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    var result = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        return err;
    };
    syntax.schema.deinit();
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    @memset(source, 'x');
    const tables = result.schema.schema.tables;
    try std.testing.expectEqual(@as(usize, 10), tables[0].indexes.len);
    for (tables[0].indexes[6..], [_]usize{ 1, 7, 8, 9 }) |index, column| {
        try std.testing.expectEqualSlices(usize, &.{column}, index.columns);
        try std.testing.expect(!index.unique);
        try std.testing.expect(index.predicate == null);
    }
    try std.testing.expectEqual(@as(usize, 0), tables[2].indexes.len);
    try std.testing.expectEqual(@as(usize, 0), tables[3].indexes.len);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(result.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/foreign_key_indexes.expect.sql"), sql.written());
}

test "automatic FK indexes cover leading full keys only; owned pipeline and OOM" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

fn collision(allocator: std.mem.Allocator, source: []const u8, table: usize) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(allocator, syntax.schema.schema);
    defer if (result == .schema) result.schema.deinit();
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(resolver.Category.sql_name_collision, result.diagnostic.category);
    try std.testing.expectEqual(syntax.schema.schema.tables[table].fields[0].span, result.diagnostic.span);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, "no automatic suffix") != null);
}

test "automatic FK deterministic name collisions report FK field spans and reclaim allocations" {
    const generated = "C {\n *pX P {\n #name `p_x`\n }\n}\nCP {\n #name `c_p`\n *x P\n}\nP {\n !id int\n}\n";
    try collision(std.testing.allocator, generated, 1);
    var generated_backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(generated_backing.allocator(), collision, .{ generated, 1 });
    for ([_][]const u8{
        "C {\n *p P? {\n #index {\n #where true\n }\n }\n}\nP {\n !id int\n}\n",
        "C {\n *p P\n}\nP {\n !id int\n}\nLater {\n #name `C_P_IDX`\n}\n",
        "C {\n *p P\n}\nP {\n !id int\n #index id {\n #name `C_P_IDX`\n }\n}\n",
        "C {\n *p P\n}\nP {\n !id int\n}\nLater {\n *p P {\n #index {\n #name `C_P_IDX`\n }\n }\n}\n",
    }) |source| {
        try collision(std.testing.allocator, source, 0);
        var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        try std.testing.checkAllAllocationFailures(backing.allocator(), collision, .{ source, 0 });
    }
}
