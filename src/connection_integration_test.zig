const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const source = @embedFile("testdata/parser/named_connections.pzl");
const expected = @embedFile("testdata/parser/named_connections.expect.sql");

fn ownedPipeline(allocator: std.mem.Allocator) !void {
    // All later reads and emission happen after both borrowed input and syntax die.
    var result = blk: {
        const text = try allocator.dupe(u8, source);
        defer allocator.free(text);
        var syntax = try parser.parse(allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        break :blk try resolver.resolve(allocator, syntax.schema.schema);
    };
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    try std.testing.expectEqual(@as(usize, 4), schema.tables.len);
    const borrow = schema.tables[2];
    try std.testing.expectEqualStrings("Borrow", borrow.dsl_name);
    try std.testing.expectEqualStrings("Borrow Exact", borrow.sql_name);
    const endpoints = borrow.connection.?.endpoints;
    try std.testing.expectEqualStrings("person", endpoints[0].role.?);
    try std.testing.expectEqualStrings("publication", endpoints[1].role.?);
    try std.testing.expectEqual(@as(usize, 0), endpoints[0].table_index);
    try std.testing.expectEqual(@as(usize, 1), endpoints[1].table_index);
    // Header order is deliberately opposite to written key order.
    try std.testing.expectEqual(@as(usize, 2), endpoints[0].column_index.?);
    try std.testing.expectEqual(@as(usize, 0), endpoints[1].column_index.?);
    try std.testing.expectEqualStrings("_sourceId", borrow.columns[2].dsl_name);
    try std.testing.expectEqualStrings("Person Ref", borrow.columns[2].sql_name);
    try std.testing.expectEqual(.real, borrow.columns[2].type);
    try std.testing.expectEqualStrings("People Exact", borrow.columns[2].foreign_key.?.target_table_sql_name);
    try std.testing.expectEqualStrings("Person Key", borrow.columns[2].foreign_key.?.target_column_sql_name);
    try std.testing.expectEqualStrings("Explicit stored borrow tuples.", borrow.documentation.?.text);
    try std.testing.expect(std.mem.indexOf(u8, source[borrow.documentation.?.span.start..borrow.documentation.?.span.end], "Explicit stored borrow tuples.") != null);
    try std.testing.expectEqualStrings("Extra value documentation.", borrow.columns[1].documentation.?.text);
    try std.testing.expect(std.mem.indexOf(u8, source[borrow.columns[1].documentation.?.span.start..borrow.columns[1].documentation.?.span.end], "Extra value documentation.") != null);
    const trio = schema.tables[3];
    const roles = [_][]const u8{ "originRole", "destinationRole", "contextRole" };
    for (trio.connection.?.endpoints, roles) |endpoint, role| {
        try std.testing.expectEqualStrings(role, endpoint.role.?);
        try std.testing.expectEqual(@as(usize, 0), endpoint.table_index);
        try std.testing.expect(endpoint.column_index == null);
    }
    try std.testing.expectEqual(@as(usize, 2), schema.relationships.len);
    const books = schema.relationships[0];
    try std.testing.expectEqualStrings("books", books.dsl_name);
    try std.testing.expectEqual(@as(usize, 0), books.owner_table_index);
    try std.testing.expectEqual(@as(usize, 1), books.target_table_index);
    try std.testing.expectEqual(@as(usize, 2), books.source_table_index);
    try std.testing.expectEqual(@as(usize, 2), books.backing_column_index);
    try std.testing.expectEqual(@as(usize, 0), books.destination_column_index.?);
    try std.testing.expectEqualStrings("Virtual books, not SQL documentation.", books.documentation.?.text);
    try std.testing.expectEqualStrings("~books Book[] @Borrow._sourceId", source[books.span.?.start..books.span.?.end]);
    const peers = schema.relationships[1];
    try std.testing.expectEqualStrings("peers", peers.dsl_name);
    try std.testing.expectEqual(@as(usize, 0), peers.owner_table_index);
    try std.testing.expectEqual(@as(usize, 0), peers.target_table_index);
    try std.testing.expectEqual(@as(usize, 3), peers.source_table_index);
    try std.testing.expectEqual(@as(usize, 3), peers.backing_column_index);
    try std.testing.expectEqual(@as(usize, 2), peers.destination_column_index.?);
    try std.testing.expectEqual(.many, peers.cardinality);
    try std.testing.expectEqualStrings("Virtual peers, preserving triples.", peers.documentation.?.text);
    try std.testing.expectEqualStrings("~peers Reader[] @Trio.origin <<destination", source[peers.span.?.start..peers.span.?.end]);
    for (schema.relationships) |relationship| {
        const doc = relationship.documentation.?;
        try std.testing.expect(std.mem.indexOf(u8, source[doc.span.start..doc.span.end], doc.text) != null);
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    emitter.emit(schema, &output.writer) catch |err| switch (err) {
        // This writer has no I/O: WriteFailed means its allocator failed.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(expected, output.written());
}

test "named explicit connection pipeline owns names docs spans and destinations after input destruction" {
    try ownedPipeline(std.testing.allocator);
}

test "named explicit connections parse resolve and emit clean up every allocation failure" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), ownedPipeline, .{});
}

test "named connection SQL is byte identical to an equivalent ordinary explicit FK table" {
    var syntax = try parser.parse(std.testing.allocator, @embedFile("testdata/parser/named_connections_ordinary.pzl"));
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.schema.schema.relationships.len);
    for (result.schema.schema.tables) |table| try std.testing.expect(table.connection == null);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(result.schema.schema, &output.writer);
    try std.testing.expectEqualStrings(expected, output.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Virtual") == null);
}
