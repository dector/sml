const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

fn uniquePipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/unique_index.sml"));
    defer allocator.free(source);
    var semantic: resolver.Result = undefined;
    {
        var syntax = try parser.parse(allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const flag = syntax.schema.schema.tables[0].fields[0].directives[1].kind.index.options[0];
        try std.testing.expect(flag.kind == .unique);
        try std.testing.expectEqualStrings("#unique", source[flag.span.start..flag.span.end]);
        semantic = try resolver.resolve(allocator, syntax.schema.schema);
    }
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    @memset(source, 'x');
    const table = semantic.schema.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 5), table.indexes.len);
    for (table.indexes, [_]bool{ true, false, true, true, false }) |index, unique|
        try std.testing.expectEqual(unique, index.unique);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, table.indexes[3].columns);
    try std.testing.expectEqualSlices(usize, table.indexes[3].columns, table.indexes[4].columns);
    try std.testing.expectEqualStrings("first lookup", table.columns[0].unique_constraints[0].name.?);
    try std.testing.expectEqualStrings("other_value_idx", semantic.schema.schema.tables[2].indexes[0].sql_name);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/unique_index.expect.sql"), sql.written());
}

test "unique indexes owned field table composite pipeline and OOM cleanup" {
    try uniquePipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), uniquePipeline, .{});
}

test "duplicate unique flags survive parsing and diagnose exact second span with OOM cleanup" {
    const source = "T {\na int\n#index a {\n#unique\n#unique\n}\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    defer syntax.schema.deinit();
    const options = syntax.schema.schema.tables[0].directives[0].kind.index.options;
    try std.testing.expectEqual(@as(usize, 2), options.len);
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer if (semantic == .schema) semantic.schema.deinit();
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(resolver.Category.duplicate_directive, semantic.diagnostic.category);
    try std.testing.expectEqual(options[1].span, semantic.diagnostic.span);
    try std.testing.expectEqualStrings("#unique", source[semantic.diagnostic.span.start..semantic.diagnostic.span.end]);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, semanticFailure, .{source});
}

test "unique index flag in indented field body and manual wrong scope" {
    const source = "T {\na int =\n  #index {\n#unique -- flag\n#name `custom`\n}\n  #name `renamed`\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    try std.testing.expect(semantic.schema.schema.tables[0].indexes[0].unique);
    try std.testing.expectEqualStrings("renamed", semantic.schema.schema.tables[0].columns[0].sql_name);
    const parsed = @import("model/parsed.zig");
    const flag: parsed.Directive = .{ .kind = .unique, .span = .{ .start = 10, .end = 17 } };
    const manual: parsed.Schema = .{ .tables = &.{.{
        .name = .{ .text = "T", .span = .{ .start = 0, .end = 1 } },
        .span = .{ .start = 0, .end = 20 },
        .directives = &.{flag},
    }} };
    const invalid = try resolver.resolve(std.testing.allocator, manual);
    try std.testing.expect(invalid == .diagnostic);
    try std.testing.expectEqual(resolver.Category.invalid_directive_scope, invalid.diagnostic.category);
    try std.testing.expectEqual(flag.span, invalid.diagnostic.span);
}

test "unique flag invalid syntax and wrong scope report exact token spans" {
    for ([_]struct { source: []const u8, token: []const u8 }{
        .{ .source = "T {\n#unique\n}\n", .token = "unique" },
        .{ .source = "T {\na int {\n#unique\n}\n}\n", .token = "unique" },
        .{ .source = "T {\na int {\n? unique {\n#unique\n}\n}\n}\n", .token = "unique" },
        .{ .source = "T {\n#index a {\n#unique()\n}\na int\n}\n", .token = "(" },
        .{ .source = "T {\n#index a {\n#unique {}\n}\na int\n}\n", .token = "{" },
    }) |case| {
        const syntax = try parser.parse(std.testing.allocator, case.source);
        try std.testing.expect(syntax == .diagnostic);
        try std.testing.expectEqualStrings(case.token, case.source[syntax.diagnostic.span.start..syntax.diagnostic.span.end]);
        const start = std.mem.indexOf(u8, case.source, "#unique").?;
        const expected_start = start + if (std.mem.eql(u8, case.token, "unique")) @as(usize, 1) else if (std.mem.eql(u8, case.token, "(")) @as(usize, 7) else @as(usize, 8);
        try std.testing.expectEqual(expected_start, syntax.diagnostic.span.start);
    }
}

test "unique and ordinary indexes share unchanged generated names and global namespace" {
    for ([_][]const u8{
        "T {\na int {\n#index\n#index {\n#unique\n}\n}\n}\n",
        "T {\na int\n#index a {\n#unique\n}\n#index a\n}\n",
        "T {\na int\n#index a {\n#unique\n#name `LATER`\n}\n}\nLater {\nb int\n}\n",
        "T {\na int\n#index a {\n#unique\n#name `U_A_IDX`\n}\n}\nU {\na int {\n#index\n}\n}\n",
    }) |source| try semanticFailure(std.testing.allocator, source);
}

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/index.sml"));
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
        "T {\n#index a {\n#unique()\n}\n}\n",
        "T {\n#index a {\n#unique `x`\n}\n}\n",
        "T {\n#index a {\n#unique {}\n}\n}\n",
        "T {\n#index a {\n#unique {\n#name `x`\n}\n}\n}\n",
        "T {\n#unique\na int\n}\n",
        "T {\na int {\n#unique\n}\n}\n",
        "T {\na int {\n? unique {\n#unique\n}\n}\n}\n",
        "T {\n#index a {\n#where\n}\n}\n",
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
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), semanticFailure, .{duplicate});
}

test "manual global index collisions and invalid later columns write nothing" {
    const first: resolved.Table = .{
        .dsl_name = "T",
        .sql_name = "t",
        .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .integer }},
        .indexes = &.{.{ .columns = &.{0}, .sql_name = "shared", .unique = true }},
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

test "manually built ordinary and unique indexes preflight whole schema before writing" {
    for ([_]bool{ false, true }) |unique| for ([_]resolved.Index{
        .{ .columns = &.{}, .sql_name = "idx", .unique = true },
        .{ .columns = &.{2}, .sql_name = "idx", .unique = true },
        .{ .columns = &.{ 0, 0 }, .sql_name = "idx", .unique = true },
        .{ .columns = &.{0}, .sql_name = "", .unique = true },
        .{ .columns = &.{0}, .sql_name = "a\x00b", .unique = true },
        .{ .columns = &.{0}, .sql_name = "sQLite_i", .unique = true },
        .{ .columns = &.{0}, .sql_name = "LATER", .unique = true },
    }) |invalid| {
        var index = invalid;
        index.unique = unique;
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
    };
}
