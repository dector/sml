const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/index.pzl"));
    defer allocator.free(source);
    var semantic: resolver.Result = undefined;
    {
        var syntax = try parser.parse(allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const payload = syntax.schema.schema.tables[0].directives[0].kind.index;
        try std.testing.expectEqualStrings("second", source[payload.fields[0].span.start..payload.fields[0].span.end]);
        const option = syntax.schema.schema.tables[0].fields[0].directives[0].kind.index.options[0];
        try std.testing.expectEqualStrings("#name #`first\" lookup`#", source[option.span.start..option.span.end]);
        semantic = try resolver.resolve(allocator, syntax.schema.schema);
    }
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    @memset(source, 'x');
    const table = semantic.schema.schema.tables[0];
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, table.indexes[3].columns);
    try std.testing.expectEqualStrings("record\" store_second value_first_idx", table.indexes[3].sql_name);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/index.expect.sql"), sql.written());
}

test "ordinary indexes owned pipeline, forward references, independent brace indentation and OOM" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "invalid index syntax, docs and unsupported options" {
    for ([_][]const u8{
        "T {\n#index\n}\n",
        "T {\n#index a,\n}\n",
        "T {\n#index a b\n}\n",
        "T {\n#index (a)\n}\n",
        "T {\n#index `a`\n}\n",
        "T {\n#index a =\n}\n",
        "T {\n#index a\n{}\n}\n",
        "T {\na int {\n#index a\n}\n}\n",
        "T {\n--- docs\n#index a\n}\n",
        "T {\n#index a {\n--- docs\n#name `n`\n}\n}\n",
        "T {\n#index a {\n#unique\n}\n}\n",
        "T {\n#index a {\n#where a > 0\n}\n}\n",
        "T {\n#index a { #name `n` }\n}\n",
        "T {\na int =\n  #index {\n#name `n`\n}\n   #name `a`\n}\n",
        "T {\n#index a {\n#name `n` }\n}\n",
    }) |source| {
        var syntax = try parser.parse(std.testing.allocator, source);
        defer if (syntax == .schema) syntax.schema.deinit();
        try std.testing.expect(syntax == .diagnostic);
    }
}

fn semanticFailure(allocator: std.mem.Allocator, source: []const u8) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(allocator, syntax.schema.schema);
    defer if (result == .schema) result.schema.deinit();
    try std.testing.expect(result == .diagnostic);
}

test "index semantic failures, exact and generated global collisions including later tables" {
    for ([_][]const u8{
        "T {\n#index missing\na int\n}\n",
        "T {\n#index a,a\na int\n}\n",
        "T {\n#index a\n#index a\na int\n}\n",
        "T {\na int {\n#index\n}\n#index a\n}\n",
        "T {\na int\n#index a {\n#name `N`\n#name `M`\n}\n}\n",
        "T {\na int\n#index a {\n#name ``\n}\n}\n",
        "T {\na int\n#index a {\n#name `n\x00x`\n}\n}\n",
        "T {\na int\n#index a {\n#name `SQLiTE_custom`\n}\n}\n",
        "SqliteData {\n#name `sqlite_data`\na int {\n#index\n}\n}\n",
        "T {\na int {\n#index\n}\n}\nLater {\n#name `T_A_IDX`\nb int\n}\n",
        "T {\na int\n#index a {\n#name `LATER`\n}\n}\nLater {\nb int\n}\n",
        "T {\na int {\n#index\n}\n}\nU {\na int\n#index a {\n#name `T_A_IDX`\n}\n}\n",
        "T {\na int\n#index a {\n#name `U_A_IDX`\n}\n}\nU {\na int {\n#index\n}\n}\n",
    }) |source| try semanticFailure(std.testing.allocator, source);
    const duplicate = "T {\na int\n#index a {\n#name `n`\n#name `m`\n}\n}\n";
    var syntax = try parser.parse(std.testing.allocator, duplicate);
    defer syntax.schema.deinit();
    try std.testing.expectEqual(@as(usize, 2), syntax.schema.schema.tables[0].directives[0].kind.index.options.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, semanticFailure, .{duplicate});
}

test "manual global index collisions and invalid later columns write nothing" {
    const first: resolved.Table = .{
        .dsl_name = "T",
        .sql_name = "t",
        .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .integer }},
        .indexes = &.{.{ .columns = &.{0}, .sql_name = "shared" }},
    };
    for ([_]resolved.Table{
        .{ .dsl_name = "U", .sql_name = "u", .columns = first.columns, .indexes = &.{.{ .columns = &.{0}, .sql_name = "SHARED" }} },
        .{ .dsl_name = "U", .sql_name = "u", .columns = &.{.{ .dsl_name = "a", .sql_name = "bad\x00name", .type = .integer }} },
        .{ .dsl_name = "U", .sql_name = "u", .columns = &.{
            .{ .dsl_name = "a", .sql_name = "name", .type = .integer },
            .{ .dsl_name = "b", .sql_name = "NAME", .type = .integer },
        } },
    }) |later| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        emitter.emit(.{ .tables = &.{ first, later } }, &sql.writer) catch {
            try std.testing.expectEqualStrings("", sql.written());
            continue;
        };
        return error.ExpectedError;
    }
}

test "manually built indexes preflight whole schema before writing" {
    for ([_]resolved.Index{
        .{ .columns = &.{}, .sql_name = "idx" },
        .{ .columns = &.{2}, .sql_name = "idx" },
        .{ .columns = &.{ 0, 0 }, .sql_name = "idx" },
        .{ .columns = &.{0}, .sql_name = "" },
        .{ .columns = &.{0}, .sql_name = "a\x00b" },
        .{ .columns = &.{0}, .sql_name = "sQLite_i" },
        .{ .columns = &.{0}, .sql_name = "LATER" },
    }) |index| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        emitter.emit(.{ .tables = &.{
            .{ .dsl_name = "T", .sql_name = "t", .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .integer }}, .indexes = &.{index} },
            .{ .dsl_name = "Later", .sql_name = "later", .columns = &.{.{ .dsl_name = "b", .sql_name = "b", .type = .integer }} },
        } }, &sql.writer) catch {
            try std.testing.expectEqualStrings("", sql.written());
            continue;
        };
        return error.ExpectedError;
    }
}
