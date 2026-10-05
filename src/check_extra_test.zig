const std = @import("std");
const emitter = @import("emitter.zig");
const parser = @import("parser.zig");
const resolved = @import("model/resolved.zig");

const span: @import("model/parsed.zig").Span = .{ .start = 0, .end = 0 };
const manual: resolved.Schema = .{ .tables = &.{.{
    .dsl_name = "T",
    .sql_name = "t",
    .columns = &.{.{
        .dsl_name = "a",
        .sql_name = "a",
        .type = .boolean,
        .checks = &.{.{ .span = span, .kind = .{ .raw_sql = "length('long trusted SQL string') > 0" } }},
    }},
}} };

fn manualPipeline(allocator: std.mem.Allocator) !void {
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(manual, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
}

test "manual field check emission allocation failures and expression writer failures propagate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, manualPipeline, .{});
    var full = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer full.deinit();
    try emitter.emit(manual, &full.writer);
    const memory = try std.testing.allocator.alloc(u8, full.written().len);
    defer std.testing.allocator.free(memory);
    for (0..memory.len) |capacity| {
        var writer = std.Io.Writer.fixed(memory[0..capacity]);
        try std.testing.expectError(error.WriteFailed, emitter.emit(manual, &writer));
    }
}

fn syntaxFailure(allocator: std.mem.Allocator) !void {
    const result = try parser.parse(allocator, "--- docs\nT {\na str {\n? (_ != 'hello' &&\n");
    try std.testing.expect(result == .diagnostic);
}

test "check syntax diagnostic allocation failures reclaim parser arena" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), syntaxFailure, .{});
}

test "cyclic manually built check is rejected before writing" {
    var expression: resolved.Expression = .{ .span = span, .kind = .null_value };
    expression.kind = .{ .grouping = &expression };
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try std.testing.expectError(error.ExcessiveDepth, emitter.emit(.{ .tables = &.{.{
        .dsl_name = "T",
        .sql_name = "t",
        .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .boolean, .checks = &.{expression} }},
    }} }, &sql.writer));
    try std.testing.expectEqualStrings("", sql.written());
}
