const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");
const date = @import("date.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    var semantic = blk: {
        const source = try allocator.dupe(u8, @embedFile("testdata/parser/date.pzl"));
        defer allocator.free(source);
        var syntax = try parser.parse(allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        break :blk try resolver.resolve(allocator, syntax.schema.schema);
    };
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    const schema = semantic.schema.schema;
    try std.testing.expectEqual(resolved.StorageType.date, schema.tables[0].columns[0].type);
    try std.testing.expectEqualStrings("2000-02-29", schema.tables[2].columns[0].default.?.date);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/date.expect.sql"), sql.written());
    var invalid_fk = schema.tables[2].columns[0];
    invalid_fk.type = .datetime;
    var invalid_table = schema.tables[2];
    invalid_table.columns = &.{invalid_fk};
    sql.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidForeignKey, emitter.emit(.{ .tables = &.{ schema.tables[0], invalid_table } }, &sql.writer));
    try std.testing.expectEqualStrings("", sql.written());
}

test "date fixture keys inherited FK checks and allocation failures" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

const invalid = [_][]const u8{ "", "0000-01-01", "10000-01-01", "1900-02-29", "2100-02-29", "2023-02-29", "2024-02-30", "2023-04-31", "2023-00-01", "2023-13-01", "2023-01-00", "2023-01-32", "2023-1-01", "2023-01-01 ", "2023-01-01\x00", "２０２３-01-01", "2023-01-01T00:00:00Z", "2023-01-01+00:00" };
fn reject(source: []const u8, category: resolver.Category) !void {
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(category, semantic.diagnostic.category);
}

test "date exact decoded literals defaults and contextual comparisons" {
    for ([_][]const u8{ "0001-01-01", "9999-12-31", "2000-02-29", "2024-02-29", "1900-02-28" }) |value| try std.testing.expect(date.valid(value));
    for (invalid) |value| {
        try std.testing.expect(!date.valid(value));
        inline for ([_][]const u8{ "T {{\n v date(##'{s}'##)\n}}\n", "T {{\n v date =\n   #check _ > ##'{s}'##\n}}\n", "T {{\n v date\n #check v == '{s}'\n}}\n" }) |format| {
            const source = try std.fmt.allocPrint(std.testing.allocator, format, .{value});
            defer std.testing.allocator.free(source);
            try reject(source, if (std.mem.indexOf(u8, format, "#check") != null) .invalid_check else .invalid_literal);
        }
    }
    try reject("T {\n d date\n t datetime\n #check d == t\n}\n", .invalid_check);
    try reject("T {\n d date\n s str\n #check d < s\n}\n", .invalid_check);
    try reject("T {\n !d date =\n   #allow reuse\n}\n", .invalid_id_reuse);
    try reject("T {\n !d date?\n}\n", .nullable_primary_key);
    try reject("T {\n d date =\n   #of x\n}\n", .invalid_directive_scope);
    for ([_][]const u8{ "1", "1.5", "true", "null" }) |value| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n d date({s})\n}}\n", .{value});
        defer std.testing.allocator.free(source);
        try reject(source, .invalid_default);
    }
    try reject("T {\n d date('2000-01-''01')\n}\n", .invalid_literal);
    try reject("P {\n !d date\n}\nC {\n *d P(::now)\n}\n", .invalid_default);
    try reject("P {\n !d date\n}\nC {\n *d P('1900-02-29')\n}\n", .invalid_literal);
    var positive = try parser.parse(std.testing.allocator, "T {\n d date?('2000-02-29')\n e date\n #check ('0001-01-01') <= d && d != null && e == d\n}\n");
    defer positive.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, positive.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    const syntax = try parser.parse(std.testing.allocator, "T {\n d date(::now)\n}\n");
    try std.testing.expect(syntax == .diagnostic);
}

test "manual date predicate literal preflight without output" {
    const left: resolved.Expression = .{ .span = .{ .start = 0, .end = 1 }, .kind = .{ .identifier = .{ .sql_name = "d" } }, .type_info = .{ .type = .date } };
    const right: resolved.Expression = .{ .span = .{ .start = 2, .end = 3 }, .kind = .{ .text = "1900-02-29" }, .type_info = .{ .type = .text } };
    const predicate: resolved.Expression = .{ .span = .{ .start = 0, .end = 3 }, .kind = .{ .binary = .{ .operator = .equal, .left = &left, .right = &right } }, .type_info = .{ .type = .boolean } };
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try std.testing.expectError(error.InvalidLiteral, emitter.emit(.{ .tables = &.{.{ .dsl_name = "T", .sql_name = "t", .columns = &.{.{ .dsl_name = "d", .sql_name = "d", .type = .date }}, .checks = &.{.{ .expression = predicate }} }} }, &sql.writer));
    try std.testing.expectEqualStrings("", sql.written());
}

test "manual date defaults preflight without output" {
    for ([_]resolved.Default{ .{ .text = "2000-01-01" }, .{ .date = "1900-02-29" }, .{ .datetime = "2000-01-01T00:00:00Z" }, .now, .null_value }) |value| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        try std.testing.expectError(error.InvalidDefault, emitter.emit(.{ .tables = &.{.{ .dsl_name = "T", .sql_name = "t", .columns = &.{.{ .dsl_name = "d", .sql_name = "d", .type = .date, .default = value }} }} }, &sql.writer));
        try std.testing.expectEqualStrings("", sql.written());
    }
}
