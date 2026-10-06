const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");

const source = @embedFile("testdata/parser/direct_relationships.sml");
const stored_source = @embedFile("testdata/parser/direct_relationships_stored.sml");
const expected = @embedFile("testdata/parser/direct_relationships.expect.sql");
const declarations = [_][]const u8{
    "~items Item[] @Item.owner",
    "~profile Item? @Item.owner",
    "~children Node[] @Node.parent",
    "~child Node? @Node.parent",
};
const docs = [_][]const u8{ "Cross collection", "Cross singular", "Self collection", "Self singular" };

fn integration(allocator: std.mem.Allocator) !void {
    var spans: [4]parsed.Span = undefined;
    var doc_spans: [4]parsed.Span = undefined;
    // All parser storage and borrowed source (including renamed SQL identifiers)
    // disappear before emission or any reads of resolved documentation.
    var result = blk: {
        const buffer = try allocator.dupe(u8, source);
        defer allocator.free(buffer);
        var syntax = try parser.parse(allocator, buffer);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var i: usize = 0;
        for (syntax.schema.schema.tables) |table| {
            for (table.relationships) |relation| {
                spans[i] = relation.span;
                doc_spans[i] = relation.documentation.?.span;
                try std.testing.expectEqualStrings(declarations[i], buffer[relation.span.start..relation.span.end]);
                try std.testing.expectEqualStrings(docs[i], relation.documentation.?.text);
                i += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 4), i);
        break :blk try resolver.resolve(allocator, syntax.schema.schema);
    };
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    var output_buffer: [expected.len]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    try emitter.emit(schema, &output);
    try std.testing.expectEqualStrings(expected, output.buffered());

    try std.testing.expectEqual(@as(usize, 4), schema.relationships.len);
    for (schema.relationships, 0..) |relation, i| {
        try std.testing.expectEqualStrings(docs[i], relation.documentation.?.text);
        try std.testing.expectEqualDeep(spans[i], relation.span.?);
        try std.testing.expectEqualDeep(doc_spans[i], relation.documentation.?.span);
        try std.testing.expectEqual(@as(usize, if (i < 2) 0 else 2), relation.owner_table_index);
        try std.testing.expectEqual(@as(usize, if (i < 2) 1 else 2), relation.target_table_index);
        try std.testing.expectEqual(relation.target_table_index, relation.source_table_index);
        try std.testing.expectEqual(@as(usize, 1), relation.backing_column_index);
        try std.testing.expectEqual(if (i % 2 == 0) resolved.RelationshipCardinality.many else .optional_one, relation.cardinality);
    }
    try std.testing.expectEqualStrings("items", schema.relationships[0].dsl_name);
    try std.testing.expectEqualStrings("profile", schema.relationships[1].dsl_name);
    try std.testing.expectEqualStrings("children", schema.relationships[2].dsl_name);
    try std.testing.expectEqualStrings("child", schema.relationships[3].dsl_name);
    try std.testing.expectEqualStrings("Owners table", schema.tables[0].documentation.?.text);
    try std.testing.expectEqualStrings("Owner key", schema.tables[0].columns[0].documentation.?.text);
    try std.testing.expectEqualStrings("Stored owner", schema.tables[1].columns[1].documentation.?.text);
    try std.testing.expectEqualStrings("Stored parent", schema.tables[2].columns[1].documentation.?.text);
    try std.testing.expectEqualStrings("Owners", schema.tables[1].columns[1].foreign_key.?.target_table_sql_name);
    try std.testing.expectEqualStrings("Key", schema.tables[1].columns[1].foreign_key.?.target_column_sql_name);
    for (schema.tables) |table| {
        try std.testing.expectEqual(@as(usize, 2), table.columns.len);
        // Real UNIQUE constraints cover the FKs; virtual declarations add none.
        try std.testing.expectEqual(@as(usize, 0), table.indexes.len);
    }

    var plain_syntax = try parser.parse(allocator, stored_source);
    defer plain_syntax.schema.deinit();
    var plain = try resolver.resolve(allocator, plain_syntax.schema.schema);
    defer plain.schema.deinit();
    var plain_buffer: [expected.len]u8 = undefined;
    var plain_output: std.Io.Writer = .fixed(&plain_buffer);
    try emitter.emit(plain.schema.schema, &plain_output);
    try std.testing.expectEqualStrings(plain_output.buffered(), output.buffered());
}

test "direct relationships preserve owned docs and spans while independent source emits identical SQL" {
    try integration(std.testing.allocator);
}

test "direct relationship integration frees every allocation under OOM" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), integration, .{});
}

test "relationship preflight precedes writer failures and valid metadata uses standard WriteFailed" {
    var syntax = try parser.parse(std.testing.allocator, source);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer result.schema.deinit();
    var writer: std.Io.Writer = .fixed(&.{});
    try std.testing.expectError(error.WriteFailed, emitter.emit(result.schema.schema, &writer));
    var bad = result.schema.schema.relationships[3];
    bad.backing_column_index = 99;
    var schema = result.schema.schema;
    schema.relationships = &.{ result.schema.schema.relationships[0], bad };
    try std.testing.expectError(error.InvalidRelationship, emitter.emit(schema, &writer));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
