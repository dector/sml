const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/foreign_keys.pzl"));
    defer allocator.free(source);
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    var semantic = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        return err;
    };
    syntax.schema.deinit();
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    @memset(source, 'x');
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/foreign_keys.expect.sql"), sql.written());
}

test "stored FK fixture, forward mutual and self references, ownership and OOM" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

fn reject(local: resolved.Column, parents: []const resolved.Column, expected: anyerror) !void {
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try std.testing.expectError(expected, emitter.emit(.{ .tables = &.{
        .{ .dsl_name = "C", .sql_name = "C", .columns = &.{local} },
        .{ .dsl_name = "P", .sql_name = "P", .columns = parents },
    } }, &sql.writer));
    try std.testing.expectEqual(@as(usize, 0), sql.written().len);
}

test "public resolved FK metadata preflight leaves output empty" {
    const key: resolved.Column = .{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard };
    const valid: resolved.Column = .{ .dsl_name = "p", .sql_name = "p", .type = .integer, .foreign_key = .{ .target_table_sql_name = "p", .target_column_sql_name = "ID" } };
    var local = valid;
    try reject(local, &.{}, error.InvalidForeignKey);
    var parent = key;
    parent.primary_key = .none;
    try reject(local, &.{parent}, error.InvalidForeignKey);
    parent = key;
    parent.sql_name = "other";
    try reject(local, &.{ key, parent }, error.InvalidForeignKey);
    local.foreign_key.?.target_table_sql_name = "missing";
    try reject(local, &.{key}, error.InvalidForeignKey);
    local = valid;
    local.foreign_key.?.target_column_sql_name = "missing";
    try reject(local, &.{key}, error.InvalidForeignKey);
    for ([_][]const u8{ "", "bad\x00name" }) |name| {
        local = valid;
        local.foreign_key.?.target_table_sql_name = name;
        try reject(local, &.{key}, error.InvalidIdentifier);
        local = valid;
        local.foreign_key.?.target_column_sql_name = name;
        try reject(local, &.{key}, error.InvalidIdentifier);
    }
    local = valid;
    local.type = .text;
    try reject(local, &.{key}, error.InvalidForeignKey);
    local = valid;
    local.primary_key = .standard;
    try reject(local, &.{key}, error.UnsupportedForeignKey);
    for ([_]resolved.DeleteAction{ .cascade, .set_null }) |action| {
        local = valid;
        local.foreign_key.?.delete_action = action;
        try reject(local, &.{key}, error.UnsupportedForeignKey);
    }
    local = valid;
    local.type = .boolean;
    parent = key;
    parent.type = .boolean;
    try reject(local, &.{parent}, error.InvalidForeignKey);
    local = valid;
    local.default = .{ .text = "bad" };
    try reject(local, &.{key}, error.InvalidDefault);
    local = valid;
    local.type = .enumeration;
    local.enum_values = &.{ "a", "b" };
    parent = key;
    parent.type = .enumeration;
    parent.enum_values = &.{ "a", "c" };
    try reject(local, &.{parent}, error.InvalidForeignKey);
    parent.enum_values = &.{ "b", "a" };
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try emitter.emit(.{ .tables = &.{
        .{ .dsl_name = "C", .sql_name = "C", .columns = &.{local} },
        .{ .dsl_name = "P", .sql_name = "P", .columns = &.{parent} },
    } }, &sql.writer);
    try std.testing.expect(std.mem.indexOf(u8, sql.written(), "REFERENCES \"p\"(\"ID\") ON DELETE RESTRICT") != null);
}
