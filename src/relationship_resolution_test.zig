const std = @import("std");
const parser = @import("parser.zig");
const parsed = @import("model/parsed.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");

const resolved = @import("model/resolved.zig");

test "singular relationship runtime fixture contains only stored enforcement SQL" {
    var syntax = try parser.parse(std.testing.allocator, @embedFile("testdata/parser/singular_relationships.pzl"));
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer result.schema.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(result.schema.schema, &output.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/singular_relationships.expect.sql"), output.written());
}

const singular_source =
    "Parent {\n #name `Owners`\n !id enum {\n #of alpha, beta\n }\n --- Singular docs\n ~profile Child? @Child.parent\n}\n" ++
    "Child {\n #name `Profiles`\n *!parent Parent\n}\n" ++
    "Node {\n !id int\n ~next Node? @Node.parent\n *parent Node? {\n ? unique\n }\n}\n";

fn singularOwned(allocator: std.mem.Allocator) !void {
    const buffer = try allocator.dupe(u8, singular_source);
    var syntax = parser.parse(allocator, buffer) catch |err| {
        allocator.free(buffer);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(buffer);
        return error.ExpectedSchema;
    }
    var result = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(buffer);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(buffer);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    try std.testing.expectEqual(.optional_one, result.schema.schema.relationships[0].cardinality);
    try std.testing.expectEqualStrings("Singular docs", result.schema.schema.relationships[0].documentation.?.text);
    try std.testing.expectEqual(.enumeration, result.schema.schema.tables[1].columns[0].type);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(result.schema.schema, &output.writer);
}

test "singular forward shared enum identity and nullable unique self FK own metadata under OOM" {
    try singularOwned(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), singularOwned, .{});
}

fn singularInvalid(allocator: std.mem.Allocator) !void {
    var syntax = try parser.parse(allocator, "Parent {\n !id int\n --- Unsupported proof\n ~profile Child? @Child.parent\n}\nChild {\n *parent Parent?\n #index parent {\n #name `partial`\n #unique\n #where true\n }\n}\n");
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(.invalid_relationship_mapping, result.diagnostic.category);
}

test "singular invalid partial proof diagnostic cleans all partial arenas under OOM" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), singularInvalid, .{});
}

test "singular requires exactly one globally unique backing column" {
    const Case = struct { field: []const u8, extra: []const u8 = "", good: bool };
    const cases = [_]Case{
        .{ .field = "*parent Parent? {\n ? unique\n }", .good = true },
        .{ .field = "*parent Parent?", .extra = "?? unique(parent)", .good = true },
        .{ .field = "*parent Parent? {\n #index {\n #unique\n }\n }", .good = true },
        .{ .field = "*parent Parent?", .extra = "#index parent {\n #unique\n }", .good = true },
        .{ .field = "*!parent Parent", .good = true },
        .{ .field = "*parent Parent?", .good = false },
        .{ .field = "*!parent Parent\n !other int", .good = false },
        .{ .field = "*parent Parent?\n other int", .extra = "?? unique(parent, other)", .good = false },
        .{ .field = "*parent Parent?\n other int", .extra = "#index parent, other {\n #unique\n }", .good = false },
        .{ .field = "*parent Parent?", .extra = "#index parent {\n #unique\n #name `partial_parent`\n #where true\n }", .good = false },
    };
    for (cases) |case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "Parent {{\n !id int\n ~profile Child? @Child.parent\n}}\nChild {{\n {s}\n {s}\n}}\n", .{ case.field, case.extra });
        defer std.testing.allocator.free(text);
        var syntax = try parser.parse(std.testing.allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        if (case.good) {
            try std.testing.expect(result == .schema);
            defer result.schema.deinit();
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();
            try emitter.emit(result.schema.schema, &output.writer);
            var stored = result.schema.schema;
            stored.relationships = &.{};
            var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer plain.deinit();
            try emitter.emit(stored, &plain.writer);
            try std.testing.expectEqualStrings(plain.written(), output.written());
        } else {
            try std.testing.expect(result == .diagnostic);
            try std.testing.expectEqual(.invalid_relationship_mapping, result.diagnostic.category);
        }
    }
}

test "public relationship preflight checks complete metadata before writes" {
    var syntax = try parser.parse(std.testing.allocator, singular_source);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer result.schema.deinit();
    const original = result.schema.schema.relationships[0];
    var variants: [16]resolved.Relationship = undefined;
    @memset(&variants, original);
    variants[0].owner_table_index = 99;
    variants[1].target_table_index = 99;
    variants[2].source_table_index = 99;
    variants[3].backing_column_index = 99;
    variants[4].source_table_index = 2;
    variants[5].owner_table_index = 2;
    variants[6].dsl_name = "";
    variants[7].dsl_name = "bad-name";
    variants[8].dsl_name = "id";
    variants[9].dsl_name = "true";
    variants[10].dsl_name = "a\x00b";
    variants[11].dsl_name = "1bad";
    variants[12].dsl_name = "false";
    variants[13].dsl_name = "null";
    variants[14].dsl_name = "_";
    variants[15].destination_column_index = 0;
    for (variants) |bad| {
        var schema = result.schema.schema;
        // A valid earlier relation must not cause any output before the bad one.
        schema.relationships = &.{ original, bad };
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectError(error.InvalidRelationship, emitter.emit(schema, &output.writer));
        try std.testing.expectEqualStrings("", output.written());
    }
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var schema = result.schema.schema;
    schema.relationships = &.{ original, original };
    try std.testing.expectError(error.InvalidRelationship, emitter.emit(schema, &output.writer));
    const columns = @constCast(schema.tables[1].columns);
    columns[0].primary_key = .none;
    schema.relationships = &.{original};
    try std.testing.expectError(error.InvalidRelationship, emitter.emit(schema, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
}

const source =
    "Parent {\n" ++
    "  #name `Owners`\n" ++
    "  --- Backref docs\n" ++
    "  ~Children Child[] @Child.parent\n" ++
    "  --- Stored key docs\n" ++
    "  !id int {\n    #name `Key`\n  }\n" ++
    "  count int {\n    #name `Children`\n  }\n" ++
    "  ~children Child[] @Child.parent\n" ++
    "}\n" ++
    "Child {\n" ++
    "  #name `Items`\n" ++
    "  note str\n" ++
    "  *parent Parent {\n    #name `OwnerKey`\n  }\n" ++
    "}\n" ++
    "Node {\n" ++
    "  !id int\n" ++
    "  ~nodes Node[] @Node.parent\n" ++
    "  *parent Node?\n" ++
    "}\n";

fn ownedCase(allocator: std.mem.Allocator) !void {
    const buffer = try allocator.dupe(u8, source);
    var syntax = parser.parse(allocator, buffer) catch |err| {
        allocator.free(buffer);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(buffer);
        return error.ExpectedSchema;
    }
    const relation_span = syntax.schema.schema.tables[0].relationships[0].span;
    const doc_span = syntax.schema.schema.tables[0].relationships[0].documentation.?.span;
    var result = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(buffer);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(buffer);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const schema = result.schema.schema;
    try std.testing.expectEqual(@as(usize, 3), schema.relationships.len);
    const first = schema.relationships[0];
    try std.testing.expectEqualStrings("Children", first.dsl_name);
    try std.testing.expectEqualStrings("Stored key docs", schema.tables[0].columns[0].documentation.?.text);
    try std.testing.expectEqualStrings(first.dsl_name, schema.tables[0].columns[1].sql_name);
    try std.testing.expectEqualStrings("Backref docs", first.documentation.?.text);
    try std.testing.expectEqualDeep(relation_span, first.span.?);
    try std.testing.expectEqualDeep(doc_span, first.documentation.?.span);
    try std.testing.expectEqual(@as(usize, 0), first.owner_table_index);
    try std.testing.expectEqual(@as(usize, 1), first.target_table_index);
    try std.testing.expectEqual(@as(usize, 1), first.source_table_index);
    try std.testing.expectEqual(@as(usize, 1), first.backing_column_index);
    try std.testing.expectEqual(.many, first.cardinality);
    try std.testing.expectEqualStrings("children", schema.relationships[1].dsl_name);
    try std.testing.expectEqual(@as(usize, 2), schema.relationships[2].owner_table_index);
    try std.testing.expectEqual(@as(usize, 2), schema.relationships[2].target_table_index);
    try std.testing.expectEqualStrings("Owners", schema.tables[1].columns[1].foreign_key.?.target_table_sql_name);
    try std.testing.expectEqualStrings("Key", schema.tables[1].columns[1].foreign_key.?.target_column_sql_name);
}

test "direct collections resolve forward self keyless targets and own all metadata" {
    try ownedCase(std.testing.allocator);
}

test "direct collection resolution releases all allocations on OOM" {
    // Arena growth must not depend on in-place resize availability.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), ownedCase, .{});
}

fn invalidCase(allocator: std.mem.Allocator) !void {
    var syntax = try parser.parse(allocator, "Parent {\n !id int\n ~kids Child[] @Child.value\n}\nChild {\n value int\n}\n");
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .diagnostic);
    try std.testing.expectEqual(.invalid_relationship_mapping, result.diagnostic.category);
}

test "invalid mapping resolution releases all allocations on diagnostic and OOM" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), invalidCase, .{});
}

test "relationship failures identify exact authored tokens and declaration spans" {
    const Case = struct { declaration: []const u8, category: resolver.Category, token: []const u8, owner_key: []const u8 = "!id int" };
    const cases = [_]Case{
        .{ .declaration = "~kids Missing[] @Child.parent", .category = .unknown_relationship_target, .token = "Missing" },
        .{ .declaration = "~kids Child[] @Missing.parent", .category = .unknown_relationship_source, .token = "Missing" },
        .{ .declaration = "~kids Child[] @Other.parent", .category = .unsupported_connection_relationship, .token = "Other" },
        .{ .declaration = "~kids Child[] @Child.missing", .category = .unknown_relationship_field, .token = "missing" },
        .{ .declaration = "~kids Child[] @Child.value", .category = .invalid_relationship_mapping, .token = "value" },
        .{ .declaration = "~kids Child[] @Child.wrong", .category = .invalid_relationship_mapping, .token = "wrong" },
        .{ .declaration = "~kids items[] @Child.parent", .category = .unknown_relationship_target, .token = "items" },
        .{ .declaration = "~kids Child[] @items.parent", .category = .unknown_relationship_source, .token = "items" },
        .{ .declaration = "~kids Child[] @Child.owner_key", .category = .unknown_relationship_field, .token = "owner_key" },
        .{ .declaration = "~id Child[] @Child.parent", .category = .duplicate_dsl_name, .token = "id" },
        .{ .declaration = "~kids Child? @Child.parent", .category = .invalid_relationship_mapping, .token = "parent" },
        .{ .declaration = "~kids Child @Child.parent", .category = .invalid_relationship_mapping, .token = "Child" },
        .{ .declaration = "~kids Child[] @Child.wrong", .category = .invalid_relationship_owner, .token = "~kids Child[] @Child.wrong", .owner_key = "value int" },
        .{ .declaration = "~kids Child[] @Child.wrong", .category = .invalid_relationship_owner, .token = "~kids Child[] @Child.wrong", .owner_key = "!id int\n !second int" },
    };
    for (cases) |case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "Parent {{\n {s}\n {s}\n}}\nChild {{\n #name `items`\n value int\n *parent Parent {{\n  #name `owner_key`\n }}\n *wrong Other\n}}\nOther {{\n !id int\n *parent Other?\n}}\n", .{ case.owner_key, case.declaration });
        defer std.testing.allocator.free(text);
        var syntax = try parser.parse(std.testing.allocator, text);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        // For invalid owner shapes remove the FK to Parent so ordinary FK
        // resolution does not reject the schema before relationship validation.
        if (!std.mem.eql(u8, case.owner_key, "!id int")) {
            const fields = @constCast(syntax.schema.schema.tables[1].fields);
            fields[1].foreign_key = false;
            fields[1].type.name.text = "int";
        }
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(case.category, result.diagnostic.category);
        const declaration_start = std.mem.indexOf(u8, text, case.declaration).?;
        const start = declaration_start + std.mem.indexOf(u8, case.declaration, case.token).?;
        try std.testing.expectEqualDeep(parsed.Span{ .start = start, .end = start + case.token.len }, result.diagnostic.span);
    }
}

test "duplicate relationship names use the exact DSL namespace" {
    var syntax = try parser.parse(std.testing.allocator, "Parent {\n !id int\n ~kids Child[] @Child.parent\n ~kids Child[] @Child.parent\n}\nChild {\n *parent Parent\n}\n");
    defer syntax.schema.deinit();
    const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expectEqual(.duplicate_dsl_name, result.diagnostic.category);
    try std.testing.expectEqualDeep(syntax.schema.schema.tables[0].relationships[1].name.span, result.diagnostic.span);
}

test "manually parsed relationship reserved names receive identifier diagnostics" {
    for ([_][]const u8{ "true", "false", "null", "_" }) |name| {
        var syntax = try parser.parse(std.testing.allocator, source);
        defer syntax.schema.deinit();
        const relationship = &@constCast(syntax.schema.schema.tables[0].relationships)[0];
        relationship.name.text = name;
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(.invalid_identifier, result.diagnostic.category);
        try std.testing.expectEqualDeep(relationship.name.span, result.diagnostic.span);
    }
}

test "manually constructed nullable collection is rejected" {
    var syntax = try parser.parse(std.testing.allocator, source);
    defer syntax.schema.deinit();
    @constCast(syntax.schema.schema.tables[0].relationships)[0].target.nullable = true;
    const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expectEqual(.invalid_relationship_mapping, result.diagnostic.category);
    try std.testing.expectEqualDeep(syntax.schema.schema.tables[0].relationships[0].target.span, result.diagnostic.span);
}

test "resolved relationships leave SQL byte for byte unchanged" {
    var syntax = try parser.parse(std.testing.allocator, source);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    defer result.schema.deinit();
    var with: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer with.deinit();
    var without: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer without.deinit();
    try emitter.emit(result.schema.schema, &with.writer);
    var stored = result.schema.schema;
    stored.relationships = &.{};
    try emitter.emit(stored, &without.writer);
    try std.testing.expectEqualStrings(without.written(), with.written());
}
