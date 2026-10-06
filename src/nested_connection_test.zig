const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");
const validation = @import("connection_validation.zig");

const parents = "Author {\n!id int\n}\nBook {\n!id int\n}\nOrganization {\n!id int\n}\n";

fn reject(allocator: std.mem.Allocator, source: []const u8, endpoint: []const u8) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(resolver.Category.unsupported_feature, result.diagnostic.category);
    try std.testing.expectEqualStrings("Nested connection endpoints are unsupported", result.diagnostic.message);
    try std.testing.expectEqualStrings(endpoint, source[result.diagnostic.span.start..result.diagnostic.span.end]);
}

test "nested named and unnamed endpoints reject explicit and generated keys in either declaration order" {
    for ([_]bool{ false, true }) |inner_unnamed| {
        const endpoint = if (inner_unnamed) "Author__n__Book" else "Authorship";
        for ([_]bool{ false, true }) |inner_generated| {
            const inner = try std.fmt.allocPrint(std.testing.allocator, "~{s}(Author, Book) {{\n{s}\n}}\n", .{
                if (inner_unnamed) "" else "Authorship",
                if (inner_generated) "~~" else "*!author Author\n*!book Book",
            });
            defer std.testing.allocator.free(inner);
            for ([_]bool{ false, true }) |outer_unnamed| {
                for ([_]bool{ false, true }) |outer_generated| {
                    const keys = try std.fmt.allocPrint(std.testing.allocator, "*!pair {s}\n*!organization Organization", .{endpoint});
                    defer std.testing.allocator.free(keys);
                    const outer = try std.fmt.allocPrint(std.testing.allocator, "~{s}(pair {s}, Organization) {{\n{s}\n}}\n", .{
                        if (outer_unnamed) "" else "Credit",
                        endpoint,
                        if (outer_generated) "~~" else keys,
                    });
                    defer std.testing.allocator.free(outer);
                    for ([_]bool{ false, true }) |forward| {
                        const source = try std.mem.concat(std.testing.allocator, u8, &.{
                            if (forward) outer else inner,
                            if (forward) inner else outer,
                            parents,
                        });
                        defer std.testing.allocator.free(source);
                        try reject(std.testing.allocator, source, endpoint);
                    }
                }
            }
        }
    }
}

fn rejectExplicit(allocator: std.mem.Allocator) !void {
    try reject(allocator, "~Credit(Authorship, Organization) {\n*!pair Authorship\n*!organization Organization\n}\n~Authorship(Author, Book) {\n*!author Author\n*!book Book\n}\n" ++ parents, "Authorship");
}

test "nested endpoint diagnostic cleans up under allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, rejectExplicit, .{});
}

test "connection endpoint cannot reference itself even with a single declared key" {
    try reject(std.testing.allocator, "~Credit(Credit, Organization) {\n!id int\n}\n" ++ parents, "Credit");
}

test "nested braces and relationship mappings through connections remain supported" {
    const source = "Author {\n!id int {\n#name `author key`\n}\n~books Book[] @Authorship.authorId\n}\nBook {\n!id int\n}\n~Authorship(Author, Book) {\n~~\n*!authorId Author {\n#onDelete cascade\n}\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.schema.schema.relationships.len);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(result.schema.schema, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "ON DELETE CASCADE") != null);
}

test "resolved nested endpoints fail connection validation and emit no SQL" {
    const parent: resolved.Table = .{
        .dsl_name = "Author",
        .sql_name = "author",
        .columns = &.{.{ .dsl_name = "id", .sql_name = "id", .type = .integer, .primary_key = .standard }},
    };
    const tables = [_]resolved.Table{
        parent,
        .{ .dsl_name = "Book", .sql_name = "book", .columns = parent.columns },
        .{ .dsl_name = "Organization", .sql_name = "organization", .columns = parent.columns },
        .{
            .dsl_name = "Authorship",
            .sql_name = "authorship",
            .columns = &.{
                .{ .dsl_name = "author", .sql_name = "author", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "author", .target_column_sql_name = "id" } },
                .{ .dsl_name = "book", .sql_name = "book", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "book", .target_column_sql_name = "id" } },
            },
            .connection = .{ .endpoints = &.{ .{ .table_index = 0, .column_index = 0 }, .{ .table_index = 1, .column_index = 1 } } },
        },
        .{
            .dsl_name = "Credit",
            .sql_name = "credit",
            .columns = &.{
                .{ .dsl_name = "pair", .sql_name = "pair", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "authorship", .target_column_sql_name = "author" } },
                .{ .dsl_name = "organization", .sql_name = "organization", .type = .integer, .primary_key = .standard, .foreign_key = .{ .target_table_sql_name = "organization", .target_column_sql_name = "id" } },
            },
            .connection = .{ .endpoints = &.{ .{ .table_index = 3, .column_index = 0 }, .{ .table_index = 2, .column_index = 1 } } },
        },
    };
    const schema: resolved.Schema = .{ .tables = &tables };
    try validation.validate(schema, tables[3]);
    try std.testing.expectError(error.InvalidConnection, validation.validate(schema, tables[4]));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidConnection, emitter.emit(schema, &output.writer));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
