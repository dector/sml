const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/named_checks.pzl"));
    var syntax = parser.parse(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(source);
        return error.ExpectedSchema;
    }
    var semantic = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(source);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(source);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    const table = semantic.schema.schema.tables[0];
    try std.testing.expectEqualStrings("range \"order\"", table.checks[0].name.?);
    try std.testing.expectEqualStrings("nonnegative `lower`", table.columns[0].checks[0].name.?);
    try std.testing.expectEqualStrings("upper ` limit", table.columns[1].checks[0].name.?);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/named_checks.expect.sql"), sql.written());
}

test "named checks source SQL names grouped expressions forward refs ownership and OOM" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "named check options reject duplicate unknown nested docs and missing expression with spans" {
    for ([_]struct { source: []const u8, bad: []const u8, message: []const u8 }{
        .{ .source = "T {\n?? true {\n#name `a`\n#name `b`\n}\n}\n", .bad = "#name `b`", .message = "duplicate #name" },
        .{ .source = "T {\n?? true {\n#unique\n}\n}\n", .bad = "unique", .message = "Only #name" },
        .{ .source = "T {\n?? true {\n#name `a` {\n}\n}\n}\n", .bad = "{", .message = "Expected end" },
        .{ .source = "T {\n?? {\n}\n}\n", .bad = "{", .message = "expression" },
        .{ .source = "T {\n?? true {\n--- docs\n#name `a`\n}\n}\n", .bad = "--- docs", .message = "Unattached documentation" },
    }) |case| {
        var syntax = try parser.parse(std.testing.allocator, case.source);
        defer if (syntax == .schema) syntax.schema.deinit();
        try std.testing.expect(syntax == .diagnostic);
        try std.testing.expectEqualStrings(case.bad, case.source[syntax.diagnostic.span.start..syntax.diagnostic.span.end]);
        try std.testing.expect(std.mem.indexOf(u8, syntax.diagnostic.message, case.message) != null);
    }
}

test "check names share table local namespace with field and table UNIQUE" {
    for ([_][]const u8{
        "T {\na int {\n? unique {\n#name `N`\n}\n? _ > 0 {\n#name `n`\n}\n}\n}\n",
        "T {\na int\n?? unique(a) {\n#name `N`\n}\n?? a > 0 {\n#name `n`\n}\n}\n",
        "T {\na int {\n? _ > 0 {\n#name `N`\n}\n}\nb int {\n? unique {\n#name `n`\n}\n}\n}\n",
        "T {\na int {\n? _ > 0 {\n#name `N`\n}\n}\n?? a > 0 {\n#name `n`\n}\n}\n",
    }) |source| {
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        defer if (semantic == .schema) semantic.schema.deinit();
        try std.testing.expect(semantic == .diagnostic);
        try std.testing.expectEqual(resolver.Category.sql_name_collision, semantic.diagnostic.category);
    }
}

test "check names are table local and invalid names keep argument spans" {
    const source = "T {\na int {\n? _ > 0 {\n#name `same`\n}\n}\n}\nU {\nb int {\n? _ > 0 {\n#name `SAME`\n}\n}\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try emitter.emit(semantic.schema.schema, &sql.writer);
    for ([_][]const u8{ "T {\n?? true {\n#name ``\n}\n}\n", "T {\n?? true {\n#name `a\x00b`\n}\n}\n", "T {\n?? true {\n#name `\xff`\n}\n}\n" }) |invalid| {
        var bad_syntax = try parser.parse(std.testing.allocator, invalid);
        try std.testing.expect(bad_syntax == .schema);
        defer bad_syntax.schema.deinit();
        var bad = try resolver.resolve(std.testing.allocator, bad_syntax.schema.schema);
        defer if (bad == .schema) bad.schema.deinit();
        try std.testing.expect(bad == .diagnostic);
        try std.testing.expectEqual(resolver.Category.invalid_identifier, bad.diagnostic.category);
        try std.testing.expectEqual(bad_syntax.schema.schema.tables[0].directives[0].check_name.?.span, bad.diagnostic.span);
    }
}

const expression: resolved.Expression = .{ .span = .{ .start = 0, .end = 0 }, .kind = .{ .raw_sql = "1" } };
test "public emitter check name preflight rejects unsafe names and cross-kind collisions without writes" {
    for ([_][]const u8{ "", "x\x00y", "\xff", "N" }) |name| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        const schema: resolved.Schema = .{ .tables = &.{.{
            .dsl_name = "T",
            .sql_name = "t",
            .checks = &.{.{ .expression = expression, .name = name }},
            .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .integer, .unique_constraints = &.{.{ .name = "n" }} }},
        }} };
        try std.testing.expectError(if (std.mem.eql(u8, name, "N")) error.SqlNameCollision else error.InvalidIdentifier, emitter.emit(schema, &sql.writer));
        try std.testing.expectEqualStrings("", sql.written());
    }
}
