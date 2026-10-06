const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const resolved = @import("model/resolved.zig");
const emitter = @import("emitter.zig");

test "hostile shared endpoint graph is rejected without exponential traversal" {
    // Each level doubles the number of paths, but has no actual key components.
    // A naive recursive proof visits 2^40 paths before discovering invalid keys.
    var tables: [41]resolved.Table = undefined;
    var endpoints: [40][2]resolved.Endpoint = undefined;
    for (0..40) |i| {
        endpoints[i] = .{ .{ .table_index = i + 1, .role = "left" }, .{ .table_index = i + 1, .role = "right" } };
        tables[i] = .{ .dsl_name = "Forged", .sql_name = "forged", .connection = .{ .endpoints = &endpoints[i] } };
    }
    tables[40] = .{ .dsl_name = "Leaf", .sql_name = "leaf" };
    const schema: resolved.Schema = .{ .tables = &tables };
    try std.testing.expectError(error.InvalidConnection, @import("connection_validation.zig").validate(schema, tables[0]));
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidConnection, emitter.emit(schema, &output.writer));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "nesting depth limit does not depend on declaration order" {
    for ([_]bool{ false, true }) |forward| {
        var source = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer source.deinit();
        try source.writer.writeAll("A {\n!id int\n}\nB {\n!id int\n}\n");
        for (0..257) |slot| {
            const i = if (forward) 256 - slot else slot;
            if (i == 0) {
                try source.writer.writeAll("~C0(A, B) {}\n");
            } else {
                try source.writer.print("~C{d}(C{d}, A) {{}}\n", .{ i, i - 1 });
            }
        }
        var syntax = try parser.parse(std.testing.allocator, source.written());
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const result = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(resolver.Category.invalid_connection, result.diagnostic.category);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, "nesting exceeds 256") != null);
    }
}
