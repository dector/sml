const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/partial_index.sml"));
    defer allocator.free(source);
    var semantic: resolver.Result = undefined;
    {
        var syntax = try parser.parse(allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        semantic = try resolver.resolve(allocator, syntax.schema.schema);
    }
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    @memset(source, 'x');
    const indexes = semantic.schema.schema.tables[0].indexes;
    try std.testing.expectEqual(@as(usize, 3), indexes.len);
    for (indexes) |index| try std.testing.expect(index.predicate != null);
    try std.testing.expect(indexes[1].unique);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/partial_index.expect.sql"), sql.written());
}

test "partial index pipeline owns predicate tree and names, forward row scope and OOM" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

fn failure(allocator: std.mem.Allocator, source: []const u8) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(allocator, syntax.schema.schema);
    defer if (semantic == .schema) semantic.schema.deinit();
    try std.testing.expect(semantic == .diagnostic);
}

test "partial predicates reject field placeholder, SQL names, unknown fields and scalar roots" {
    for ([_][]const u8{ "_ > 0", "missing > 0", "actual > 0", "1", "'text'", "null", "a" }) |predicate| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\na int {{\n#name `actual`\n#index {{\n#where {s}\n}}\n}}\n}}\n", .{predicate});
        defer std.testing.allocator.free(source);
        try failure(std.testing.allocator, source);
        var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        try std.testing.checkAllAllocationFailures(backing.allocator(), failure, .{source});
    }
}

test "predicate semantic errors retain exact reference and root spans" {
    for ([_][]const u8{ "missing", "_", "1" }) |bad| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\na int\n#index a {{\n#where {s}\n}}\n}}\n", .{bad});
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        defer syntax.schema.deinit();
        const semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(semantic == .diagnostic);
        try std.testing.expectEqual(resolver.Category.invalid_index, semantic.diagnostic.category);
        try std.testing.expectEqualStrings(bad, source[semantic.diagnostic.span.start..semantic.diagnostic.span.end]);
    }
}

test "raw SQL partial restrictions are trusted not statically checked" {
    const source = "T {\na int\n#index a {\n#where `random() > ? OR EXISTS (SELECT 1)`\n}\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    const predicate = semantic.schema.schema.tables[0].indexes[0].predicate.?;
    try std.testing.expectEqualStrings("random() > ? OR EXISTS (SELECT 1)", predicate.kind.raw_sql);
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try emitter.emit(semantic.schema.schema, &sql.writer);
    try std.testing.expect(std.mem.endsWith(u8, sql.written(), " WHERE (random() > ? OR EXISTS (SELECT 1));\n"));
}

test "duplicate where preserved and exact second directive diagnosed" {
    const source = "T {\na int\n#index a {\n#where a > 0\n#where a < 10\n}\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    defer syntax.schema.deinit();
    const options = syntax.schema.schema.tables[0].directives[0].kind.index.options;
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expect(options[0].kind == .where and options[1].kind == .where);
    const semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(resolver.Category.duplicate_directive, semantic.diagnostic.category);
    try std.testing.expectEqual(options[1].span, semantic.diagnostic.span);
    try std.testing.expectEqualStrings("#where a < 10", source[semantic.diagnostic.span.start..semantic.diagnostic.span.end]);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), failure, .{source});
}

test "partial and ordinary indexes still need distinct explicit names" {
    try failure(std.testing.allocator, "T {\na int\n#index a\n#index a {\n#where a > 0\n}\n}\n");
}

test "missing predicate unsupported options docs and standalone where have exact syntax spans" {
    for ([_]struct { source: []const u8, token: []const u8 }{
        .{ .source = "T {\na int\n#index a {\n#where\n}\n}\n", .token = "\n" },
        .{ .source = "T {\na int\n#index a {\n#where {}\n}\n}\n", .token = "{" },
        .{ .source = "T {\na int\n#index a {\n#unknown\n}\n}\n", .token = "unknown" },
        .{ .source = "T {\na int\n#where a > 0\n}\n", .token = "where" },
        .{ .source = "T {\na int\n#index a {\n--- docs\n#where a > 0\n}\n}\n", .token = "--- docs" },
        .{ .source = "T {\na int\n#index (a > 0)\n}\n", .token = "(" },
    }) |case| {
        const syntax = try parser.parse(std.testing.allocator, case.source);
        try std.testing.expect(syntax == .diagnostic);
        try std.testing.expectEqualStrings(case.token, case.source[syntax.diagnostic.span.start..syntax.diagnostic.span.end]);
    }
}

test "direct malformed predicate preflight writes nothing even in later table" {
    const span = @import("model/parsed.zig").Span{ .start = 0, .end = 1 };
    const scalar: resolved.Expression = .{ .span = span, .kind = .{ .integer = 1 } };
    for ([_]resolved.Expression{
        .{ .span = span, .kind = .{ .integer = 1 }, .type_info = .{ .type = .boolean, .nullable = false } },
        .{ .span = span, .kind = .{ .binary = .{ .operator = .is_null, .left = &scalar, .right = &scalar } }, .type_info = .{ .type = .boolean } },
        .{ .span = span, .kind = .{ .raw_sql = "" } },
        .{ .span = span, .kind = .{ .raw_sql = "x\x00y" } },
        .{ .span = span, .kind = .{ .identifier = .{ .sql_name = "bad\x00name" } }, .type_info = .{ .type = .boolean, .nullable = false } },
    }) |predicate| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        emitter.emit(.{ .tables = &.{
            .{ .dsl_name = "Earlier", .sql_name = "earlier", .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .integer }} },
            .{ .dsl_name = "Later", .sql_name = "later", .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .integer }}, .indexes = &.{.{ .columns = &.{0}, .sql_name = "idx", .predicate = predicate }} },
        } }, &sql.writer) catch {
            try std.testing.expectEqualStrings("", sql.written());
            continue;
        };
        return error.ExpectedError;
    }
}
