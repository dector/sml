const std = @import("std");
const parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");
const resolved = @import("model/resolved.zig");
const datetime = @import("datetime.zig");

fn pipeline(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, @embedFile("testdata/parser/datetime.pzl"));
    var syntax = parser.parse(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    if (syntax != .schema) {
        allocator.free(source);
        return error.ExpectedSchema;
    }
    const generator = syntax.schema.schema.tables[0].fields[1].default.?.generator;
    try std.testing.expectEqualStrings("::now", generator.text);
    try std.testing.expectEqualStrings(generator.text, source[generator.span.start..generator.span.end]);
    var semantic = resolver.resolve(allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        allocator.free(source);
        return err;
    };
    syntax.schema.deinit();
    allocator.free(source);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    const columns = semantic.schema.schema.tables[0].columns;
    try std.testing.expectEqual(resolved.StorageType.datetime, columns[0].type);
    try std.testing.expectEqualStrings("2000-02-29T23:59:59Z", columns[0].default.?.datetime);
    try std.testing.expect(columns[1].default.? == .now);
    var sql = std.Io.Writer.Allocating.init(allocator);
    defer sql.deinit();
    emitter.emit(semantic.schema.schema, &sql.writer) catch |err| switch (err) {
        // Allocating writer translates allocator failures to WriteFailed.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/datetime.expect.sql"), sql.written());
}

test "datetime source to SQL, ownership, and allocation failures" {
    try pipeline(std.testing.allocator);
    // Arena growth can otherwise change allocation counts during the sweep.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), pipeline, .{});
}

const valid_values = [_][]const u8{
    "0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "2000-02-29T12:34:56Z",
    "2024-02-29T00:00:00Z", "1900-02-28T00:00:00Z", "2023-04-30T00:00:00Z",
};
const invalid_values = [_][]const u8{
    "",                          "0000-01-01T00:00:00Z",  "10000-01-01T00:00:00Z",    "1900-02-29T00:00:00Z",
    "2100-02-29T00:00:00Z",      "2023-02-29T00:00:00Z",  "2024-02-30T00:00:00Z",     "2023-04-31T00:00:00Z",
    "2023-00-01T00:00:00Z",      "2023-13-01T00:00:00Z",  "2023-01-00T00:00:00Z",     "2023-01-32T00:00:00Z",
    "2023-01-01T24:00:00Z",      "2023-01-01T00:60:00Z",  "2023-01-01T00:00:60Z",     "2023-01-01T00:00:00.000Z",
    "2023-01-01T00:00:00+00:00", "2023-01-01T00:00:00z",  "2023-01-01t00:00:00Z",     "2023-1-01T00:00:00Z",
    "2023-01-01 00:00:00Z",      "2023-01-01T00:00:00Z ", "2023-01-01T00:00:00Z\x00", "abcd-ef-ghTij:kl:mnZ",
    "2023-01-01T00:00:00",
};

fn reject(allocator: std.mem.Allocator, source: []const u8, category: resolver.Category, spelling: []const u8) !void {
    var syntax = try parser.parse(allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const semantic = try resolver.resolve(allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(category, semantic.diagnostic.category);
    try std.testing.expectEqualStrings(spelling, source[semantic.diagnostic.span.start..semantic.diagnostic.span.end]);
}

test "datetime exact format and Gregorian calendar resolved after string decoding" {
    for (valid_values) |value| {
        try std.testing.expect(datetime.valid(value));
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n v datetime(##'{s}'##)\n}}\n", .{value});
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        defer syntax.schema.deinit();
        var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(semantic == .schema);
        defer semantic.schema.deinit();
        try std.testing.expectEqualStrings(value, semantic.schema.schema.tables[0].columns[0].default.?.datetime);
    }
    for (invalid_values) |value| {
        try std.testing.expect(!datetime.valid(value));
        const literal = try std.fmt.allocPrint(std.testing.allocator, "'{s}'", .{value});
        defer std.testing.allocator.free(literal);
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n v datetime({s})\n}}\n", .{literal});
        defer std.testing.allocator.free(source);
        try reject(std.testing.allocator, source, .invalid_literal, literal);
    }
}

test "datetime default compatibility, generators and key policies" {
    for ([_][]const u8{ "1", "1.0", "true", "false", "null" }) |literal| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n v datetime({s})\n}}\n", .{literal});
        defer std.testing.allocator.free(source);
        try reject(std.testing.allocator, source, .invalid_default, literal);
    }
    try reject(std.testing.allocator, "T {\n v datetime(::uuid)\n}\n", .invalid_literal, "::uuid");
    try reject(std.testing.allocator, "T {\n v datetime(::nowLater)\n}\n", .invalid_literal, "::nowLater");
    try reject(std.testing.allocator, "T {\n !v datetime?\n}\n", .nullable_primary_key, "datetime?");
    try reject(std.testing.allocator, "T {\n !v datetime =\n   #allow reuse\n}\n", .invalid_id_reuse, "#allow reuse");
    for ([_][]const u8{ "::now {}", "T {\n ::now datetime\n}\n", "T {\n v datetime(:: now)\n}\n", "T {\n v datetime(::now())\n}\n", "T {\n v datetime =\n   #onUpdate ::now\n}\n", "T {\n v str(::now)\n}\n" }) |source| {
        const syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .diagnostic);
    }
    var scanner = tokenizer.Tokenizer.init("now ::now datetime");
    for ([_]tokenizer.Kind{ .identifier, .generator, .identifier }) |kind|
        try std.testing.expectEqual(kind, scanner.next().token.kind);
}

fn diagnosticFailure(allocator: std.mem.Allocator) !void {
    try reject(allocator, "--- docs\nT {\n a datetime(::now)\n b datetime('1900-02-29T00:00:00Z')\n}\n", .invalid_literal, "'1900-02-29T00:00:00Z'");
}

test "datetime diagnostics reclaim every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, diagnosticFailure, .{});
}

test "emitter validates datetime defaults before writing including manual models" {
    const cases = [_]struct { type: resolved.StorageType, value: resolved.Default }{
        .{ .type = .datetime, .value = .{ .text = "2000-01-01T00:00:00Z" } },
        .{ .type = .datetime, .value = .{ .datetime = "1900-02-29T00:00:00Z" } },
        .{ .type = .datetime, .value = .{ .integer = 1 } },
        .{ .type = .datetime, .value = .{ .real = 1 } },
        .{ .type = .datetime, .value = .{ .boolean = true } },
        .{ .type = .datetime, .value = .{ .blob = "x" } },
        .{ .type = .datetime, .value = .null_value },
        .{ .type = .text, .value = .{ .datetime = "2000-01-01T00:00:00Z" } },
        .{ .type = .text, .value = .now },
        .{ .type = .integer, .value = .now },
    };
    for (cases) |case| {
        var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer sql.deinit();
        try std.testing.expectError(error.InvalidDefault, emitter.emit(.{ .tables = &.{.{
            .dsl_name = "T",
            .sql_name = "t",
            .columns = &.{.{
                .dsl_name = "v",
                .sql_name = "v",
                .type = case.type,
                .default = case.value,
            }},
        }} }, &sql.writer));
        try std.testing.expectEqualStrings("", sql.written());
    }
}
