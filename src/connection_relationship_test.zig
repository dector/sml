const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

test "connection relationship runtime fixture emits only stored objects" {
    var syntax = try parser.parse(std.testing.allocator, @embedFile("testdata/parser/connection_relationships.sml"));
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(result.schema.schema, &output.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/connection_relationships.expect.sql"), output.written());
}

const source =
    "Reader {\n #name `people`\n !id int {\n #name `reader_key`\n }\n" ++
    " ~following Reader[] @Following.leftReader\n ~followers Reader[] @Following.rightReader <<leftReader\n" ++
    " ~books Book[] @Borrow.reader\n ~one Book? @Single.reader\n ~pairs Reader[] @Trio.first <<second\n}\n" ++
    "Book {\n !id int\n}\n" ++
    "~Following(follower Reader, followed Reader) {\n #name `edges`\n *!leftReader Reader {\n #name `from_key`\n }\n *!rightReader Reader {\n #name `to_key`\n }\n}\n" ++
    "~Borrow(Reader, Book) {\n *!reader Reader\n *!book Book\n}\n" ++
    "~Single(Reader, Book) {\n *!reader Reader {\n ? unique\n }\n *!book Book\n}\n" ++
    "~Trio(firstRole Reader, secondRole Reader, thirdRole Reader) {\n *!first Reader\n *!second Reader\n *!third Reader\n}\n";

fn owned(allocator: std.mem.Allocator) !void {
    const text = try allocator.dupe(u8, source);
    defer allocator.free(text);
    var syntax = try parser.parse(allocator, text);
    defer syntax.schema.deinit();
    try std.testing.expect(syntax == .schema);
    var result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    try std.testing.expectEqual(@as(usize, 5), schema.relationships.len);
    const first = schema.relationships[0];
    try std.testing.expectEqual(@as(usize, 0), first.owner_table_index);
    try std.testing.expectEqual(@as(usize, 0), first.target_table_index);
    try std.testing.expectEqual(@as(usize, 2), first.source_table_index);
    try std.testing.expectEqual(@as(usize, 0), first.backing_column_index);
    try std.testing.expectEqual(@as(usize, 1), first.destination_column_index.?);
    try std.testing.expectEqual(@as(usize, 0), schema.relationships[1].destination_column_index.?);
    try std.testing.expectEqual(.optional_one, schema.relationships[3].cardinality);
    try std.testing.expectEqualStrings("leftReader", schema.tables[2].columns[0].dsl_name);
    try std.testing.expectEqualStrings("from_key", schema.tables[2].columns[0].sql_name);
    try std.testing.expect(schema.tables[2].connection.?.endpoints[0].column_index == null);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(schema, &output.writer);
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    var stored = schema;
    stored.relationships = &.{};
    try emitter.emit(stored, &plain.writer);
    try std.testing.expectEqualStrings(plain.written(), output.written());
}

test "named connection mappings infer endpoints, use DSL hints, and own forward metadata under OOM" {
    try owned(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), owned, .{});
}

fn invalid(allocator: std.mem.Allocator) !void {
    var syntax = try parser.parse(allocator, "Reader {\n !id int\n ~bad Reader[] @Trio.first\n}\n~Trio(a Reader, b Reader, c Reader) {\n *!first Reader\n *!second Reader\n *!third Reader\n}\n");
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(.invalid_relationship_mapping, result.diagnostic.category);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, "Ambiguous") != null);
}

test "ambiguous destination failure cleans up under OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, invalid, .{});
}

test "connection mapping rejects invalid source and destination DSL fields and cardinality" {
    const cases = [_][]const u8{
        "~r Reader[] @Following.leftReader <<leftReader",
        "~r Reader[] @Following.leftReader <<from_key",
        "~r Reader[] @Following.leftReader <<missing",
        "~r Book[] @Following.leftReader",
        "~r Book[] @Following.leftReader <<rightReader",
        "~r Reader[] @Following.extra <<rightReader",
        "~r Reader[] @Following.payload <<rightReader",
        "~r Reader[] @Following.missing",
        "~r Reader? @Following.leftReader",
        "~r Reader @Following.leftReader",
        "~r Reader[] @Direct.reader <<reader",
        "~r Book[] @Direct.reader",
        "~r Reader[] @Following.rightReader <<extra",
    };
    for (cases) |declaration| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "Reader {{\n !id int\n {s}\n}}\nBook {{\n !id int\n}}\n~Following(a Reader, b Reader) {{\n *!leftReader Reader {{\n #name `from_key`\n }}\n *!rightReader Reader\n *extra Reader\n payload int\n}}\nDirect {{\n *reader Reader\n}}\n", .{declaration});
        defer std.testing.allocator.free(text);
        var syntax = try parser.parse(std.testing.allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
    }
}

test "single comparison remains valid and destination shift is not an expression operator" {
    var syntax = try parser.parse(std.testing.allocator, "A {\n !id int\n value int {\n ? _ < 3\n }\n}\n");
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const bad = try parser.parse(std.testing.allocator, "A {\n value int {\n ? _ << 3\n }\n}\n");
    try std.testing.expect(bad == .diagnostic);
}

test "destination hint spans and malformed hint parser failures" {
    const text = "Reader {\n ~r Reader[] @Following.leftReader <<rightReader\n}\n";
    var syntax = try parser.parse(std.testing.allocator, text);
    defer syntax.schema.deinit();
    const r = syntax.schema.schema.tables[0].relationships[0];
    try std.testing.expectEqualStrings("rightReader", r.destination_field.?.text);
    try std.testing.expectEqualStrings("rightReader", text[r.destination_field.?.span.start..r.destination_field.?.span.end]);
    try std.testing.expectEqualStrings("~r Reader[] @Following.leftReader <<rightReader", text[r.span.start..r.span.end]);
    const tails = [_][]const u8{ "<<", "<<right <<left", "<<right bits", "<<right #name `oops`" };
    for (tails) |tail| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "Reader\n  ~r Reader[] @Following.leftReader {s}", .{tail});
        defer std.testing.allocator.free(input);
        const result = try parser.parse(std.testing.allocator, input);
        try std.testing.expect(result == .diagnostic);
    }
}

test "emitter validates complete connection mapping before whole model output" {
    var syntax = try parser.parse(std.testing.allocator, source);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer result.schema.deinit();
    const original = result.schema.schema.relationships[0];
    var variants: [9]resolved.Relationship = undefined;
    @memset(&variants, original);
    variants[0].destination_column_index = null;
    variants[1].destination_column_index = 0;
    variants[2].destination_column_index = 99;
    variants[3].backing_column_index = 99;
    variants[4].owner_table_index = 1;
    variants[5].target_table_index = 1;
    variants[6].source_table_index = 1;
    variants[7].cardinality = .optional_one;
    variants[8].source_table_index = 3;
    for (variants) |bad| {
        var schema = result.schema.schema;
        var renamed = bad;
        renamed.dsl_name = "bad";
        schema.relationships = &.{ original, renamed };
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectError(error.InvalidRelationship, emitter.emit(schema, &output.writer));
        try std.testing.expectEqualStrings("", output.written());
    }
    var schema = result.schema.schema;
    const tables = @constCast(schema.tables);
    const metadata = tables[2].connection;
    tables[2].connection = null;
    schema.relationships = &.{original};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidRelationship, emitter.emit(schema, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
    tables[2].connection = metadata;
}
