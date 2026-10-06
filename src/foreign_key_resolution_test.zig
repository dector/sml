const std = @import("std");
const parser = @import("parser.zig");
const parsed = @import("model/parsed.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");

const source =
    "Child {\n" ++
    "  --- Local docs.\n" ++
    "  *owner Parent?(ready) {\n    #name `Owner Exact`\n    #check _ != null\n    ? unique\n  }\n" ++
    "  *other Parent(`two words`)\n" ++
    "  *stamp Clock(::now)\n" ++
    "  *literal Clock('2000-02-29T00:00:00Z')\n" ++
    "  *plain Parent\n" ++
    "  *hyphen Parent(two-words)\n" ++
    "  *word Parent(true)\n" ++
    "  #check owner != other\n" ++
    "  #index owner\n" ++
    "}\n" ++
    "Parent {\n  #name `Parent Exact`\n  --- Target docs.\n  !key enum(ready) {\n    #of ready, `two words`, two-words, true\n    #name `Key Exact`\n    #check _ != `no`\n    ? unique\n  }\n}\n" ++
    "Clock {\n  !key datetime\n}\n" ++
    "Node {\n  !id int\n  *parent Node?\n}\n";

fn pipeline(allocator: std.mem.Allocator) !void {
    const owned_source = try allocator.dupe(u8, source);
    var syntax = parser.parse(allocator, owned_source) catch |err| {
        allocator.free(owned_source);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(owned_source);
        return error.ExpectedSyntax;
    }
    var result = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(owned_source);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(owned_source);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const tables = result.schema.schema.tables;
    const owner = tables[0].columns[0];
    try std.testing.expectEqual(resolved.StorageType.enumeration, owner.type);
    try std.testing.expectEqualStrings("Parent Exact", owner.foreign_key.?.target_table_sql_name);
    try std.testing.expectEqualStrings("Key Exact", owner.foreign_key.?.target_column_sql_name);
    try std.testing.expectEqualStrings("Owner Exact", owner.sql_name);
    try std.testing.expectEqualStrings("Local docs.", owner.documentation.?.text);
    try std.testing.expectEqualStrings("two words", owner.enum_values[1]);
    try std.testing.expectEqualStrings("ready", owner.default.?.text);
    try std.testing.expectEqualStrings("two words", tables[0].columns[1].default.?.text);
    try std.testing.expect(tables[0].columns[1].documentation == null);
    try std.testing.expectEqual(@as(usize, 0), tables[0].columns[1].checks.len);
    try std.testing.expectEqual(@as(usize, 0), tables[0].columns[1].unique_constraints.len);
    try std.testing.expect(owner.nullable);
    try std.testing.expect(!tables[0].columns[1].nullable);
    try std.testing.expectEqual(resolved.PrimaryKey.none, owner.primary_key);
    try std.testing.expectEqual(resolved.DeleteAction.restrict, owner.foreign_key.?.delete_action);
    try std.testing.expectEqual(@as(usize, 1), owner.checks.len);
    try std.testing.expectEqual(@as(usize, 1), owner.unique_constraints.len);
    try std.testing.expectEqual(@as(usize, 1), tables[0].checks.len);
    try std.testing.expectEqual(@as(usize, 1), tables[0].indexes.len);
    try std.testing.expectEqual(resolved.StorageType.datetime, tables[0].columns[2].type);
    try std.testing.expect(tables[0].columns[2].default.? == .now);
    try std.testing.expectEqualStrings("2000-02-29T00:00:00Z", tables[0].columns[3].default.?.datetime);
    try std.testing.expect(tables[0].columns[4].default == null);
    try std.testing.expectEqualStrings("two-words", tables[0].columns[5].default.?.text);
    try std.testing.expectEqualStrings("true", tables[0].columns[6].default.?.text);
    try std.testing.expectEqualStrings("node", tables[3].columns[1].foreign_key.?.target_table_sql_name);
    try std.testing.expectEqual(resolved.StorageType.integer, tables[3].columns[1].type);
    try std.testing.expectEqual(@as(usize, 0), tables[3].indexes.len);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    try std.testing.expectError(error.UnsupportedForeignKey, emitter.emit(result.schema.schema, &sql.writer));
    try std.testing.expectEqual(@as(usize, 0), sql.written().len);
}

test "forward self exact owned names inherited enum datetime defaults and local constraints" {
    try pipeline(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

fn reject(allocator: std.mem.Allocator, input: []const u8, category: resolver.Category, span_text: []const u8) !void {
    var syntax = try parser.parse(allocator, input);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var result = try resolver.resolve(allocator, syntax.schema.schema);
    if (result == .schema) {
        result.schema.deinit();
        return error.ExpectedDiagnostic;
    }
    try std.testing.expectEqual(category, result.diagnostic.category);
    try std.testing.expectEqualStrings(span_text, input[result.diagnostic.span.start..result.diagnostic.span.end]);
}

test "FK target diagnostics and inherited default validation have precise spans" {
    const cases = .{
        .{ "C {\n *p Missing\n}\n", .unknown_foreign_key_target, "Missing" },
        .{ "C {\n *p P\n}\nP {\n value int\n}\n", .invalid_foreign_key_target, "P" },
        .{ "C {\n *p P\n}\nP {\n !a int\n !b int\n}\n", .invalid_foreign_key_target, "P" },
        .{ "C {\n *p P\n}\nP {\n !a bool\n}\n", .invalid_primary_key, "bool" },
        .{ "C {\n *p P\n}\nP {\n !a int?\n}\n", .nullable_primary_key, "int?" },
        .{ "C {\n *p P(no)\n}\nP {\n !a enum =\n   #of yes\n}\n", .invalid_default, "no" },
        .{ "C {\n *p P(`no`)\n}\nP {\n !a enum =\n   #of yes\n}\n", .invalid_default, "`no`" },
        .{ "C {\n *p P(null)\n}\nP {\n !a int\n}\n", .invalid_default, "null" },
        .{ "C {\n *p P('1900-02-29T00:00:00Z')\n}\nP {\n !a datetime\n}\n", .invalid_literal, "'1900-02-29T00:00:00Z'" },
        .{ "C {\n *p P =\n   #allow reuse\n}\nP {\n !a int\n}\n", .invalid_id_reuse, "#allow reuse" },
        .{ "C {\n *!p P =\n   #allow reuse\n}\nP {\n !a int\n}\n", .invalid_id_reuse, "#allow reuse" },
        .{ "C {\n *p P =\n   #of yes\n}\nP {\n !a int\n}\n", .invalid_directive_scope, "#of yes" },
        .{ "C {\n *p P\n}\nP {\n *!key Q\n}\nQ {\n !key str\n}\n", .unsupported_feature, "*!key Q" },
        .{ "C {\n *p P\n}\nP {\n *!key Q\n}\nQ {\n *!key P\n}\n", .foreign_key_cycle, "Q" },
        .{ "P {\n *!key P\n}\n", .foreign_key_cycle, "P" },
    };
    inline for (cases) |case| try reject(std.testing.allocator, case[0], case[1], case[2]);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), reject, .{ "P {\n *!key P\n}\n", resolver.Category.foreign_key_cycle, "P" });
}

fn manual(allocator: std.mem.Allocator) !void {
    const span: parsed.Span = .{ .start = 10, .end = 11 };
    const input: parsed.Schema = .{ .tables = &.{
        .{ .name = .{ .text = "C", .span = span }, .span = span, .fields = &.{.{ .name = .{ .text = "p", .span = span }, .span = span, .foreign_key = true, .type = .{ .name = .{ .text = "P", .span = span }, .span = span } }} },
        .{ .name = .{ .text = "P", .span = span }, .span = span, .fields = &.{.{ .name = .{ .text = "id", .span = span }, .span = span, .primary_key = true, .type = .{ .name = .{ .text = "int", .span = span }, .span = span } }} },
    } };
    var result = try resolver.resolve(allocator, input);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    try std.testing.expectEqualStrings("p", result.schema.schema.tables[0].columns[0].foreign_key.?.target_table_sql_name);
}

test "manual parsed FK models reclaim allocation failures" {
    try manual(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), manual, .{});
}
