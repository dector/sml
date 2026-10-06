const std = @import("std");
const parser = @import("parser.zig");

fn syntax(allocator: std.mem.Allocator) !void {
    const source = "T {\n --- Owner.\n *p T? {\n #onDelete cascade\n #onDelete restrict\n }\n *q T? =\n   #onDelete setNull\n onDelete str\n cascade str\n setNull str\n}\n";
    var result = try parser.parse(allocator, source);
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const fields = result.schema.schema.tables[0].fields;
    try std.testing.expectEqualStrings("Owner.", fields[0].documentation.?.text);
    try std.testing.expectEqual(@as(usize, 2), fields[0].directives.len);
    for (fields[0].directives, [_][]const u8{ "cascade", "restrict" }) |directive, action| {
        try std.testing.expectEqualStrings(action, directive.kind.on_delete.text);
        try std.testing.expectEqualStrings(action, source[directive.kind.on_delete.span.start..directive.kind.on_delete.span.end]);
        try std.testing.expectEqualStrings("#onDelete", source[directive.span.start .. directive.span.start + 9]);
        try std.testing.expectEqual(directive.kind.on_delete.span.end, directive.span.end);
    }
    try std.testing.expectEqualStrings("#onDelete setNull", source[fields[1].directives[0].span.start..fields[1].directives[0].span.end]);
}

test "delete action contextual words docs duplicates bodies spans and OOM" {
    try syntax(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), syntax, .{});
}

test "delete action malformed syntax options docs and unsupported update exact spans" {
    const cases = .{
        .{ "T {\n *p T =\n   #onDelete\n}\n", "\n", "#onDelete requires an action identifier (restrict, cascade or setNull)" },
        .{ "T {\n *p T =\n   #onDelete 'cascade'\n}\n", "'cascade'", "#onDelete requires an action identifier (restrict, cascade or setNull)" },
        .{ "T {\n *p T =\n   #onDelete cascade()\n}\n", "(", "Expected end of line; unsupported syntax or mixed body forms" },
        .{ "T {\n *p T =\n   #onUpdate cascade\n}\n", "onUpdate", "#onUpdate is unsupported; foreign-key update actions are not supported" },
        .{ "T {\n #index p {\n #onDelete cascade\n }\n}\n", "onDelete", "Only #name, #unique and #where are supported in index options" },
    };
    inline for (cases) |case| {
        var result = try parser.parse(std.testing.allocator, case[0]);
        if (result == .schema) {
            result.schema.deinit();
            return error.ExpectedDiagnostic;
        }
        try std.testing.expectEqualStrings(case[1], case[0][result.diagnostic.span.start..result.diagnostic.span.end]);
        try std.testing.expectEqualStrings(case[2], result.diagnostic.message);
    }
}
