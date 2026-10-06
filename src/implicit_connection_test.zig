const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const fixture = @embedFile("testdata/parser/implicit_connections.pzl");

fn pipeline(allocator: std.mem.Allocator) !void {
    var result = blk: {
        const text = try allocator.dupe(u8, fixture);
        defer allocator.free(text);
        var syntax = try parser.parse(allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const r = syntax.schema.schema.tables[0].relationships[0];
        try std.testing.expect(r.source_implicit);
        try std.testing.expectEqualStrings("", r.source_table.text);
        try std.testing.expectEqualStrings("@.", text[r.source_table.span.start..r.source_table.span.end]);
        const semantic = try resolver.resolve(allocator, syntax.schema.schema);
        try std.testing.expect(syntax.schema.schema.tables.len == 2);
        try std.testing.expect(syntax.schema.schema.tables[0].relationships[0].source_implicit);
        break :blk semantic;
    };
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    try std.testing.expectEqual(@as(usize, 3), schema.tables.len);
    for (schema.relationships) |r| try std.testing.expectEqual(@as(usize, 2), r.source_table_index);
    const connection = schema.tables[2].connection.?;
    try std.testing.expect(connection.unnamed);
    try std.testing.expectEqualStrings("Author", connection.identity.?.endpoints[0]);
    try std.testing.expectEqualStrings("authorId", schema.tables[2].columns[0].dsl_name);
    try std.testing.expectEqual(@as(usize, 0), connection.endpoints[0].column_index.?);
    try std.testing.expectEqual(@as(usize, 1), connection.endpoints[1].column_index.?);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    emitter.emit(schema, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/implicit_connections.expect.sql"), out.written());
    var stored = schema;
    stored.relationships = &.{};
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    emitter.emit(stored, &plain.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(out.written(), plain.written());
}

test "implicit opposite sides share one owned canonical connection including OOM" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "implicit pairs append in globally sorted order independent of relationship traversal" {
    var baseline: ?[]u8 = null;
    defer if (baseline) |sql| std.testing.allocator.free(sql);
    for ([_][]const u8{
        "~cs C[] @.aId\n~bs B[] @.aId\n",
        "~bs B[] @.aId\n~cs C[] @.aId\n",
    }) |relationships| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "A {{\n!id int\n{s}}}\nC {{\n!id int\n}}\nB {{\n!id int\n}}\n~Named(B, A) {{\n~~\n}}\n", .{relationships});
        defer std.testing.allocator.free(text);
        var syntax = try parser.parse(std.testing.allocator, text);
        defer syntax.schema.deinit();
        var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .schema);
        defer result.schema.deinit();
        try std.testing.expectEqualStrings("A__n__B", result.schema.schema.tables[4].dsl_name);
        try std.testing.expectEqualStrings("A__n__C", result.schema.schema.tables[5].dsl_name);
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try emitter.emit(result.schema.schema, &out.writer);
        if (baseline) |sql| try std.testing.expectEqualStrings(sql, out.written()) else baseline = try std.testing.allocator.dupe(u8, out.written());
    }
}

test "explicit unnamed wins even later with authored arbitrary keys and unique singular mapping" {
    const text = "A {\n!id int\n~b B? @.owner <<other\n}\nB {\n!id int\n}\n~(B, A) {\n#name `custom links`\n*!other B\n*!owner A {\n? unique\n}\n}\n";
    var syntax = try parser.parse(std.testing.allocator, text);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    try std.testing.expectEqual(@as(usize, 3), schema.tables.len);
    try std.testing.expectEqualStrings("custom links", schema.tables[2].sql_name);
    try std.testing.expectEqualStrings("other", schema.tables[2].columns[0].dsl_name);
    try std.testing.expectEqual(@as(usize, 1), schema.relationships[0].backing_column_index);
}

test "implicit diagnostics reject self nested missing keys fields hints singular and collisions" {
    const cases = [_][2][]const u8{
        .{ "A {\n!id int\n~a A[] @.aId\n}\n", "distinct normal tables" },
        .{ "A {\n!id int\n~b B[] @.aId\n}\n", "Unknown implicit" },
        .{ "A {\n!id int\n~b B[] @.aId\n}\nB {\n!x int\n!y int\n}\n", "exactly one" },
        .{ "A {\n!id int\n~b B[] @.missing\n}\nB {\n!id int\n}\n", "Unknown stored DSL field" },
        .{ "A {\n!id int\n~b B[] @.aId <<aId\n}\nB {\n!id int\n}\n", "Destination" },
        .{ "A {\n!id int\n~b B? @.aId\n}\nB {\n!id int\n}\n", "unique" },
        .{ "A {\n!id int\n~b B[] @.aId\n}\nB {\n!id int\n}\n~(A, B) {}\n", "key" },
        .{ "A {\n!id int\n~b B[] @.aId\n}\nB {\n!id int\n}\n~(A, B) {\n*!owner A\n*!other B\n}\n", "Unknown stored DSL field" },
        .{ "A {\n!id int\n~b B[] @.aId\n}\nB {\n!id int\n}\nOther {\n#name `A__N__B`\n}\n", "SQL" },
        .{ "A {\n!id int\n~b B[] @.aId\n}\nB {\n!id int\n}\n~(A, B) {\n~~\n}\n~(B, A) {\n~~\n}\n", "Duplicate unnamed" },
        .{ "A {\n!id int\n~b B[] @.aId\n}\nB {\n!id int\n}\nA__n__B {}\n", "duplicate DSL" },
        .{ "A {\n!id int\n~b Link[] @.aId\n}\nB {\n!id int\n}\n~Link(A, B) {\n~~\n}\n", "normal tables" },
    };
    for (cases) |case| {
        var syntax = try parser.parse(std.testing.allocator, case[0]);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        if (std.mem.indexOf(u8, result.diagnostic.message, case[1]) == null) {
            std.debug.print("expected {s}, got {s}\n", .{ case[1], result.diagnostic.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "implicit generated names follow enum and FK primary-key chains using DSL names" {
    const text = "E {\n!code enum {\n #of one, two\n}\n}\nA_table {\n*!local_key E\n~bs B_table[] @.aTableLocalKey\n}\nB_table {\n#name `different`\n!other_key int\n}\n";
    var syntax = try parser.parse(std.testing.allocator, text);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const table = result.schema.schema.tables[3];
    try std.testing.expectEqualStrings("aTableLocalKey", table.columns[0].dsl_name);
    try std.testing.expectEqualStrings("bTableOtherKey", table.columns[1].dsl_name);
}

fn invalidOwned(allocator: std.mem.Allocator) !void {
    var syntax = try parser.parse(allocator, "A {\n!id int\n~b B[] @.aId\n}\nB {\n!id int\n}\n~(B, A) {\n*!owner A\n*!other B\n}\n");
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(resolver.Category.unknown_relationship_field, result.diagnostic.category);
}

test "implicit reuse failure cleans up under OOM and manual sentinel is validated" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, invalidOwned, .{});
    var syntax = try parser.parse(std.testing.allocator, fixture);
    defer syntax.schema.deinit();
    const tables = try std.testing.allocator.dupe(@import("model/parsed.zig").Table, syntax.schema.schema.tables);
    defer std.testing.allocator.free(tables);
    var r = tables[0].relationships[0];
    r.source_table.text = "unexpected";
    tables[0].relationships = &.{r};
    const result = try resolver.resolve(std.testing.allocator, .{ .tables = tables });
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(resolver.Category.invalid_relationship_mapping, result.diagnostic.category);
}

test "implicit reuse preserves explicit generated key SQL override without DSL renaming" {
    var syntax = try parser.parse(std.testing.allocator, "A {\n!id int\n~b B[] @.aId\n}\nB {\n!id int\n}\n~(B, A) {\n#name `links`\n~~\n*!aId A {\n#name `owner`\n#onDelete cascade\n}\n}\n");
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    try std.testing.expectEqual(@as(usize, 3), schema.tables.len);
    try std.testing.expectEqualStrings("aId", schema.tables[2].columns[0].dsl_name);
    try std.testing.expectEqualStrings("owner", schema.tables[2].columns[0].sql_name);
    try std.testing.expectEqualStrings("links", schema.tables[2].sql_name);
    try std.testing.expectEqual(@as(usize, 0), schema.relationships[0].backing_column_index);
}
