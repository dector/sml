const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const tokenizer = @import("tokenizer.zig");
const resolved = @import("model/resolved.zig");

const source =
    "Child {\n" ++
    "  --- Forward owner.\n" ++
    "  *owner Parent?(null) {\n" ++
    "    #name `owner`\n" ++
    "    ? unique\n" ++
    "  }\n" ++
    "  --- Shared identity.\n" ++
    "  *!parent Parent =\n" ++
    "    #allow reuse\n" ++
    "  *!other Parent\n" ++
    "  *self Child?\n" ++
    "  plain int\n" ++
    "}\n" ++
    "Parent {\n  !id int\n}\n";

fn syntaxCase(allocator: std.mem.Allocator) !void {
    var result = try parser.parse(allocator, source);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const fields = result.schema.schema.tables[0].fields;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    const owner = fields[0];
    try std.testing.expect(owner.foreign_key);
    try std.testing.expect(!owner.primary_key);
    try std.testing.expectEqualStrings("owner", owner.name.text);
    try std.testing.expectEqualStrings("Forward owner.", owner.documentation.?.text);
    try std.testing.expectEqualStrings("Parent", owner.type.name.text);
    try std.testing.expectEqual(@intFromPtr(source.ptr) + owner.type.name.span.start, @intFromPtr(owner.type.name.text.ptr));
    try std.testing.expectEqualStrings("Parent?", source[owner.type.span.start..owner.type.span.end]);
    try std.testing.expectEqualStrings("*owner Parent?(null) {\n    #name `owner`\n    ? unique\n  }", source[owner.span.start..owner.span.end]);
    try std.testing.expect(owner.default.? == .null_value);
    try std.testing.expectEqual(@as(usize, 2), owner.directives.len);
    for (fields[1..3]) |field| {
        try std.testing.expect(field.foreign_key);
        try std.testing.expect(field.primary_key);
    }
    try std.testing.expectEqualStrings("Shared identity.", fields[1].documentation.?.text);
    try std.testing.expectEqualStrings("*!parent Parent =\n    #allow reuse", source[fields[1].span.start..fields[1].span.end]);
    try std.testing.expect(fields[1].directives[0].kind == .allow_reuse);
    try std.testing.expectEqualStrings("Child", fields[3].type.name.text);
    try std.testing.expect(fields[3].type.nullable);
    try std.testing.expect(!fields[4].foreign_key);
    try std.testing.expect(!fields[4].primary_key);
    try std.testing.expect(!result.schema.schema.tables[1].fields[0].foreign_key);
    try std.testing.expect(result.schema.schema.tables[1].fields[0].primary_key);
}

test "stored FK syntax preserves forward self composite membership docs bodies and spans" {
    // Five fields, including two independent FK primary-key components.
    try syntaxCase(std.testing.allocator);
}

test "star token and EOF have exact spans" {
    var lexer = tokenizer.Tokenizer.init("*!");
    const star = lexer.next().token;
    try std.testing.expectEqual(tokenizer.Kind.star, star.kind);
    try std.testing.expectEqual(@as(usize, 0), star.span.start);
    try std.testing.expectEqual(@as(usize, 1), star.span.end);
    try std.testing.expectEqualStrings("*", star.text);
    try std.testing.expectEqual(tokenizer.Kind.bang, lexer.next().token.kind);
    const eof = lexer.next().token;
    try std.testing.expectEqual(tokenizer.Kind.eof, eof.kind);
    try std.testing.expectEqual(@as(usize, 2), eof.span.start);
    try std.testing.expectEqual(eof.span.start, eof.span.end);
}

fn failureCase(allocator: std.mem.Allocator, input: []const u8, start: usize, end: usize) !void {
    var result = try parser.parse(allocator, input);
    if (result == .schema) {
        result.schema.deinit();
        return error.ExpectedSyntaxDiagnostic;
    }
    try std.testing.expectEqual(start, result.diagnostic.span.start);
    try std.testing.expectEqual(end, result.diagnostic.span.end);
}

test "stored FK rejects reversed repeated incomplete markers and composite reference syntax" {
    const cases = .{
        .{ "T {\n  !*owner Owner\n}\n", 7, 8 },
        .{ "T {\n  **owner Owner\n}\n", 7, 8 },
        .{ "T {\n  *!!owner Owner\n}\n", 8, 9 },
        .{ "T {\n  *", 7, 7 },
        .{ "T {\n  *!", 8, 8 },
        .{ "T {\n  *owner", 12, 12 },
        .{ "T {\n  *owner Owner, Other\n}\n", 18, 19 },
        .{ "T {\n  *owner Owner[]\n}\n", 18, 19 },
        .{ "T {\n  ~owner Owner\n}\n", 18, 19 },
        .{ "~(Owner, T) {}\n", 0, 2 },
    };
    inline for (cases) |case| try failureCase(std.testing.allocator, case[0], case[1], case[2]);
}

fn sharedIdentityCase(allocator: std.mem.Allocator, input: []const u8) !void {
    var syntax = try parser.parse(allocator, input);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const field = result.schema.schema.tables[0].columns[0];
    try std.testing.expectEqual(resolved.PrimaryKey.standard, field.primary_key);
    try std.testing.expectEqual(resolved.StorageType.integer, field.type);
    try std.testing.expect(!field.nullable);
}

test "stored FK primary shared identity resolves" {
    try sharedIdentityCase(std.testing.allocator, "Label {\n  *!owner Owner\n}\nOwner {\n  !id int\n}\n");
}

test "FK metadata defaults and inherited logical types remain separate from PK policy" {
    const fk: resolved.ForeignKey = .{ .target_table_sql_name = "parent", .target_column_sql_name = "key" };
    try std.testing.expectEqual(resolved.DeleteAction.restrict, fk.delete_action);
    const plain: resolved.Column = .{ .dsl_name = "plain", .sql_name = "plain", .type = .boolean };
    try std.testing.expectEqual(@as(?resolved.ForeignKey, null), plain.foreign_key);
    const column: resolved.Column = .{
        .dsl_name = "owner",
        .sql_name = "owner",
        .type = .enumeration,
        .enum_values = &.{"allowed"},
        .foreign_key = fk,
        .primary_key = .standard,
    };
    try std.testing.expectEqual(resolved.StorageType.enumeration, column.type);
    try std.testing.expectEqualStrings("allowed", column.enum_values[0]);
    try std.testing.expectEqual(resolved.PrimaryKey.standard, column.primary_key);
}

test "FK syntax and shared identity resolution reclaim every allocation failure" {
    // Disable in-place arena growth to keep failure-sweep counts deterministic.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), syntaxCase, .{});
    try std.testing.checkAllAllocationFailures(backing.allocator(), sharedIdentityCase, .{"Label {\n  *!owner Owner\n}\nOwner {\n  !id int\n}\n"});
    try std.testing.checkAllAllocationFailures(backing.allocator(), failureCase, .{ "T {\n  --- Owner.\n  *!", 21, 21 });
}
