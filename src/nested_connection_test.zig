const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");
const validation = @import("connection_validation.zig");

const parents = "Author {\n!id int\n}\nBook {\n!id int\n}\nOrganization {\n!id int\n}\n";

fn pipeline(allocator: std.mem.Allocator, source: []const u8) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    emitter.emit(result.schema.schema, &output.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "FOREIGN KEY (") != null);
    for (result.schema.schema.tables) |table| {
        if (table.composite_foreign_keys.len == 0) continue;
        for (table.composite_foreign_keys) |fk| {
            try std.testing.expect(fk.columns.len >= 2);
            for (fk.columns) |ci| try std.testing.expect(table.columns[ci].foreign_key.?.composite);
        }
    }
}

test "nested named and unnamed endpoints support explicit and generated keys in either declaration order" {
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
                        try pipeline(std.testing.allocator, source);
                    }
                }
            }
        }
    }
}

const deep_source = "~Deep(Credit, Book) {\n~~\n}\n~Credit(pair Authorship, Organization) {\n~~\n}\n~Authorship(Author, Book) {\n*!book Book\n*!author Author\n}\n" ++ parents;

fn owned(allocator: std.mem.Allocator) !void {
    var result = blk: {
        const source = try allocator.dupe(u8, deep_source);
        defer allocator.free(source);
        var syntax = try parser.parse(allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        break :blk try resolver.resolve(allocator, syntax.schema.schema);
    };
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    const credit = schema.tables[1];
    try std.testing.expectEqual(@as(usize, 3), credit.columns.len);
    try std.testing.expectEqualStrings("pairBook", credit.columns[0].dsl_name);
    try std.testing.expectEqualStrings("pairAuthor", credit.columns[1].dsl_name);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, credit.connection.?.endpoints[0].column_indices);
    try std.testing.expect(credit.connection.?.endpoints[0].column_index == null);
    try std.testing.expectEqual(@as(usize, 4), schema.tables[0].columns.len);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    emitter.emit(schema, &output.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "REFERENCES \"authorship\" (\"book\", \"author\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "REFERENCES \"credit\" (\"pair_book\", \"pair_author\", \"organization_id\")") != null);
}

test "nested endpoint ownership key order and full pipeline allocation failures" {
    try owned(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), owned, .{});
}

test "repeated nested endpoints have disjoint complete role bindings" {
    const source = "~Pair(left Authorship, right Authorship) {\n~~\n}\n~Authorship(Author, Book) {\n~~\n}\n" ++ parents;
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const table = result.schema.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 4), table.columns.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, table.connection.?.endpoints[0].column_indices);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, table.connection.?.endpoints[1].column_indices);
    try std.testing.expectEqual(@as(usize, 2), table.composite_foreign_keys.len);
    try pipeline(std.testing.allocator, source);
    try pipeline(std.testing.allocator, "~Pair(left Authorship, right Authorship) {\n*!first Authorship\n*!second Authorship\n}\n~Authorship(Author, Book) {\n~~\n}\n" ++ parents);
}

fn reject(source: []const u8, category: resolver.Category, fragment: []const u8, message: []const u8) !void {
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(category, result.diagnostic.category);
    try std.testing.expectEqualStrings(fragment, source[result.diagnostic.span.start..result.diagnostic.span.end]);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, message) != null);
}

test "nested endpoint cycles and invalid tuple options are diagnosed" {
    try reject("~Credit(Credit, Organization) {\n~~\n}\n" ++ parents, .invalid_connection, "Credit", "cycle");
    try reject("~First(Second, Book) {\n~~\n}\n~Second(First, Author) {\n~~\n}\n" ++ parents, .invalid_connection, "First", "cycle");
    try reject("~Credit(Authorship, Organization) {\n*!pair Authorship {\n#name `tuple`\n}\n*!org Organization\n}\n~Authorship(Author, Book) {\n~~\n}\n" ++ parents, .invalid_connection, "#name `tuple`", "only accepts #onDelete");
    try reject("~Credit(Authorship, Organization) {\n*!pair Authorship?\n*!org Organization\n}\n~Authorship(Author, Book) {\n~~\n}\n" ++ parents, .invalid_connection, "Authorship?", "nonnullable");
    try reject("~Credit(Authorship, Organization) {\n*!pair Authorship\n*!pairAuthorId Author\n*!org Organization\n}\n~Authorship(Author, Book) {\n~~\n}\n" ++ parents, .duplicate_dsl_name, "pairAuthorId", "duplicate");
}

test "nested braces and scalar relationship mappings through connections remain supported" {
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

test "generated tuple groups use endpoint identity rather than naming prefix" {
    try pipeline(std.testing.allocator, "~Outer(Authorship, Authorship Other) {\n~~\n}\n" ++
        "~Authorship(Author, Book) {\n*!writer Author\n*!publication Book\n}\n" ++
        "~Other(Author, Book) {\n*!person Author\n*!work Book\n}\n" ++ parents);
}

test "nested key components inherit logical types and exact SQL aliases" {
    const source =
        "~Credit(pair Authorship, Organization) {\n~~\n*!pairAuthorId Authorship {\n#name `local writer`\n}\n}\n" ++
        "~Authorship(Author, Book) {\n#name `Author Book Pairs`\n~~\n*!authorId Author {\n#name `Writer Key`\n}\n}\n" ++
        "Author {\n!id enum {\n#of writer, editor\n}\n}\nBook {\n!id date\n}\nOrganization {\n!id str\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const credit = result.schema.schema.tables[0];
    try std.testing.expectEqual(resolved.StorageType.enumeration, credit.columns[0].type);
    try std.testing.expectEqualStrings("writer", credit.columns[0].enum_values[0]);
    try std.testing.expectEqual(resolved.StorageType.date, credit.columns[1].type);
    try std.testing.expectEqualStrings("local writer", credit.columns[0].sql_name);
    try std.testing.expectEqualStrings("Author Book Pairs", credit.columns[0].foreign_key.?.target_table_sql_name);
    try std.testing.expectEqualStrings("Writer Key", credit.columns[0].foreign_key.?.target_column_sql_name);
    try pipeline(std.testing.allocator, source);
}

test "forged nested endpoint bindings and incomplete composite FKs emit no SQL" {
    var syntax = try parser.parse(std.testing.allocator, deep_source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const tables = try std.testing.allocator.dupe(resolved.Table, result.schema.schema.tables);
    defer std.testing.allocator.free(tables);
    const original = tables[1];
    const endpoints = try std.testing.allocator.dupe(resolved.Endpoint, original.connection.?.endpoints);
    defer std.testing.allocator.free(endpoints);
    tables[1].connection.?.endpoints = endpoints;
    const schema: resolved.Schema = .{ .tables = tables };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    for (0..4) |case| {
        tables[1].composite_foreign_keys = original.composite_foreign_keys;
        endpoints[0] = original.connection.?.endpoints[0];
        switch (case) {
            0 => endpoints[0].column_indices = &.{ 1, 0 },
            1 => endpoints[0].column_indices = &.{0},
            2 => tables[1].composite_foreign_keys = &.{},
            3 => endpoints[0].table_index = 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidConnection, validation.validate(schema, tables[1]));
        if (case == 2) {
            try std.testing.expectError(error.InvalidForeignKey, emitter.emit(schema, &output.writer));
        } else {
            try std.testing.expectError(error.InvalidConnection, emitter.emit(schema, &output.writer));
        }
        try std.testing.expectEqual(@as(usize, 0), output.written().len);
    }
}
