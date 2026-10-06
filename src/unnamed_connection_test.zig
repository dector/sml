const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");
const fixture = @embedFile("testdata/parser/unnamed_connections.pzl");
const parents = "Author {\n#name `Writer`\n!id int\n}\nBook {\n!id int\n}\n";

fn pipeline(allocator: std.mem.Allocator) !void {
    var result = blk: {
        const source = try allocator.dupe(u8, fixture);
        defer allocator.free(source);
        var syntax = try parser.parse(allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const table = syntax.schema.schema.tables[0];
        try std.testing.expectEqualStrings("Author__n__Book", table.name.text);
        try std.testing.expectEqualStrings("~(Book, Author)", source[table.name.span.start..table.name.span.end]);
        try std.testing.expect(table.connection.?.unnamed);
        const semantic = try resolver.resolve(allocator, syntax.schema.schema);
        try std.testing.expectEqualStrings("Book", table.connection.?.endpoints[0].table.text);
        try std.testing.expectEqualStrings("bookId", table.fields[0].name.text);
        break :blk semantic;
    };
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    const table = schema.tables[0];
    try std.testing.expectEqualStrings("authorId", table.columns[0].dsl_name);
    try std.testing.expectEqualStrings("bookId", table.columns[1].dsl_name);
    const connection = table.connection.?;
    try std.testing.expect(connection.unnamed);
    try std.testing.expectEqualStrings("Author", connection.identity.?.endpoints[0]);
    for (connection.endpoints, 0..) |endpoint, i| try std.testing.expectEqual(i, endpoint.column_index.?);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    emitter.emit(schema, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/unnamed_connections.expect.sql"), out.written());
}

test "unnamed fixture owns synthesized names and identity after source freed" {
    try pipeline(std.testing.allocator);
}
test "unnamed full pipeline allocation failures" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

test "reversed unnamed headers generate identical SQL but authored keys retain order" {
    var baseline: ?[]u8 = null;
    defer if (baseline) |sql| std.testing.allocator.free(sql);
    for ([_][]const u8{
        "~(Book, Author) {\n~~\n*!bookId Book {\n#name `volume`\n}\n}\n",
        "~(Author, Book) {\n*!bookId Book {\n#name `volume`\n}\n~~\n}\n",
        "~(Book, Author) {\n*!authorId Author\n*!bookId Book {\n#name `volume`\n}\n}\n",
        "~(Author, Book) {\n*!bookId Book\n*!authorId Author\n}\n",
    }, 0..) |body, n| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ body, parents });
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .schema);
        defer result.schema.deinit();
        const table = result.schema.schema.tables[0];
        try std.testing.expectEqualStrings("author__n__book", table.sql_name);
        try std.testing.expectEqualStrings(if (n == 3) "bookId" else "authorId", table.columns[0].dsl_name);
        try std.testing.expectEqual(@as(usize, if (n == 3) 1 else 0), table.connection.?.endpoints[0].column_index.?);
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try emitter.emit(result.schema.schema, &out.writer);
        if (n == 3) continue;
        if (baseline) |sql| try std.testing.expectEqualStrings(sql, out.written()) else baseline = try std.testing.allocator.dupe(u8, out.written());
    }
}

test "unnamed duplicate identities precede aliases and use full header spans" {
    const body = "~(Author, Book) {\n#name `one`\n~~\n}\n~(Book, Author) {\n#name `two`\n~~\n}\n";
    const source = try std.mem.concat(std.testing.allocator, u8, &.{ body, parents });
    defer std.testing.allocator.free(source);
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(resolver.Category.duplicate_dsl_name, result.diagnostic.category);
    try std.testing.expectEqualStrings("~(Book, Author)", source[result.diagnostic.span.start..result.diagnostic.span.end]);
    try std.testing.expectEqualStrings("Duplicate unnamed connection identity", result.diagnostic.message);
}

test "unnamed rejects missing explicit keys and namespace collisions" {
    const Case = struct { body: []const u8, category: resolver.Category };
    for ([_]Case{
        .{ .body = "~(Author, Book) {}\n", .category = .invalid_connection },
        .{ .body = "~(Author, Book) {\n~~\n}\nAuthor__n__Book {}\n", .category = .duplicate_dsl_name },
        .{ .body = "~(Author, Book) {\n~~\n}\nOther {\n#name `AUTHOR__N__BOOK`\n}\n", .category = .sql_name_collision },
        .{ .body = "~(Book, Author) {\n~~\n*!bookId Author\n}\n", .category = .invalid_connection },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ case.body, parents });
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(case.category, result.diagnostic.category);
    }
}

test "named connections share endpoints and synthesized DSL mappings resolve" {
    const source = "~(Book, Author) {\n~~\n}\n~Named(Book, Author) {\n~~\n}\nAuthor {\n!id int\n~books Book[] @Author__n__Book.authorId\n}\nBook {\n!id int\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.schema.schema.relationships.len);
    try std.testing.expect(!result.schema.schema.tables[1].connection.?.unnamed);
}

test "emitter rejects noncanonical and duplicate unnamed public metadata before output" {
    var syntax = try parser.parse(std.testing.allocator, fixture);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer result.schema.deinit();
    const original = result.schema.schema;
    const tables = try std.testing.allocator.dupe(resolved.Table, original.tables);
    defer std.testing.allocator.free(tables);
    const endpoints = try std.testing.allocator.dupe(resolved.Endpoint, tables[0].connection.?.endpoints);
    defer std.testing.allocator.free(endpoints);
    tables[0].connection.?.endpoints = endpoints;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    std.mem.swap(resolved.Endpoint, &endpoints[0], &endpoints[1]);
    try std.testing.expectError(error.InvalidConnection, emitter.emit(.{ .tables = tables }, &out.writer));
    std.mem.swap(resolved.Endpoint, &endpoints[0], &endpoints[1]);
    endpoints[0].role = "writer";
    try std.testing.expectError(error.InvalidConnection, emitter.emit(.{ .tables = tables }, &out.writer));
    endpoints[0].role = null;
    const identity = tables[0].connection.?.identity;
    tables[0].connection.?.identity = null;
    try std.testing.expectError(error.InvalidConnection, emitter.emit(.{ .tables = tables }, &out.writer));
    tables[0].connection.?.identity = identity;
    const duplicated = try std.testing.allocator.alloc(resolved.Table, tables.len + 1);
    defer std.testing.allocator.free(duplicated);
    @memcpy(duplicated[0..tables.len], tables);
    duplicated[tables.len] = tables[0];
    duplicated[tables.len].sql_name = "another alias";
    try std.testing.expectError(error.InvalidConnection, emitter.emit(.{ .tables = duplicated }, &out.writer));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
