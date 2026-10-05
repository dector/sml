const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    var syntax = try parser.parse(allocator, @embedFile("testdata/parser/unique.pzl"));
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const directive = syntax.schema.schema.tables[0].fields[0].directives[2];
    try std.testing.expect(directive.kind == .native_unique);
    try std.testing.expectEqual(@as(usize, 0), directive.kind.native_unique.fields.len);
    try std.testing.expectEqualStrings("#name #`code\"constraint`#", @embedFile("testdata/parser/unique.pzl")[directive.kind.native_unique.options[0].span.start..directive.kind.native_unique.options[0].span.end]);
    var semantic = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    try std.testing.expectEqualStrings("code\"constraint", semantic.schema.schema.tables[0].columns[0].unique_constraints[0].name.?);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/unique.expect.sql"), sql.written());
}

test "native field uniqueness pipeline and allocation failures" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "unique syntax rejects deferred features and invalid option bodies" {
    for ([_][]const u8{
        "T {\n?? unique(a,b)\n}\n",
        "T {\na str {\n? unique(nulls: equal)\n}\n}\n",
        "T {\na str {\n? unique =\n}\n}\n",
        "T {\na str {\n? unique {\n#allow reuse\n}\n}\n}\n",
        "T {\na str {\n? unique {\n#name = `n`\n}\n}\n}\n",
        "T {\na str {\n? unique {\n--- docs\n#name `n`\n}\n}\n}\n",
        "T {\na str {\n--- docs\n? unique\n}\n}\n",
    }) |source| {
        var syntax = try parser.parse(std.testing.allocator, source);
        defer if (syntax == .schema) syntax.schema.deinit();
        try std.testing.expect(syntax == .diagnostic);
    }
}

test "unique duplicates are preserved then rejected; identifiers remain expressions" {
    for ([_][]const u8{
        "T {\na str {\n? unique\n#check unique\n}\n}\n",
        "T {\na str {\n? unique {\n#name `n`\n#name `m`\n}\n}\n}\n",
        "T {\na str {\n? unique {\n#name ``\n}\n}\n}\n",
        "T {\na str {\n? unique {\n#name `a\x00b`\n}\n}\n}\n",
        "T {\na str {\n? unique {\n#name `N`\n}\n}\nb str {\n? unique {\n#name `n`\n}\n}\n}\n",
        "T {\nunique str\na str {\n? unique == 'x'\n}\n}\n",
    }, 0..) |source, i| {
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        if (i == 0) try std.testing.expectEqual(@as(usize, 2), syntax.schema.schema.tables[0].fields[0].directives.len);
        if (i == 1) try std.testing.expectEqual(@as(usize, 2), syntax.schema.schema.tables[0].fields[0].directives[0].kind.native_unique.options.len);
        if (i == 5) try std.testing.expect(syntax.schema.schema.tables[0].fields[1].directives[0].kind == .check);
        var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        defer if (semantic == .schema) semantic.schema.deinit();
        try std.testing.expect(semantic == .diagnostic);
    }
    var syntax = try parser.parse(std.testing.allocator, "T {\nunique str {\n? unique == 'x'\n}\n}\n");
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer if (semantic == .schema) semantic.schema.deinit();
    try std.testing.expect(semantic == .diagnostic);
}

test "manual unique models preflight before any output" {
    for ([_][]const resolved.UniqueConstraint{
        &.{.{ .name = "" }}, &.{.{ .name = "a\x00b" }}, &.{.{ .nulls = .equal }}, &.{ .{}, .{} },
    }) |uniques| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        emitter.emit(.{ .tables = &.{.{ .dsl_name = "T", .sql_name = "t", .columns = &.{.{ .dsl_name = "a", .sql_name = "a", .type = .text, .unique_constraints = uniques }} }} }, &output.writer) catch {
            try std.testing.expectEqualStrings("", output.written());
            continue;
        };
        return error.ExpectedError;
    }
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidUnique, emitter.emit(.{ .tables = &.{.{ .dsl_name = "T", .sql_name = "t", .columns = &.{
        .{ .dsl_name = "a", .sql_name = "a", .type = .text, .unique_constraints = &.{.{ .name = "N" }} },
        .{ .dsl_name = "b", .sql_name = "b", .type = .text, .unique_constraints = &.{.{ .name = "n" }} },
    } }} }, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
    const span: parsed.Span = .{ .start = 0, .end = 1 };
    for ([_]parsed.NativeUnique{
        .{ .fields = &.{.{ .text = "a", .span = span }} },
        .{ .options = &.{.{ .kind = .allow_reuse, .span = span }} },
    }) |unique| {
        var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{.{ .name = .{ .text = "T", .span = span }, .span = span, .fields = &.{.{ .name = .{ .text = "a", .span = span }, .type = .{ .name = .{ .text = "str", .span = span }, .span = span }, .span = span, .directives = &.{.{ .kind = .{ .native_unique = unique }, .span = span }} }} }} });
        defer if (result == .schema) result.schema.deinit();
        try std.testing.expect(result == .diagnostic);
    }
}
