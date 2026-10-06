const std = @import("std");
const parser = @import("parser.zig");
const parsed = @import("model/parsed.zig");
const resolver = @import("resolver.zig");

fn borrowed(source: []const u8, token: parsed.Token) !void {
    try std.testing.expectEqualStrings(token.text, source[token.span.start..token.span.end]);
    try std.testing.expectEqual(@intFromPtr(source.ptr) + token.span.start, @intFromPtr(token.text.ptr));
}

test "named connection is a marked ordinary table with explicit keys and body metadata" {
    const source =
        "--- Credits\n--- Stored explicitly\n-- attachment\n~Authorship(Author, Book) {\n" ++
        "  #name `book_credits`\n" ++
        "  --- Author key\n  *!authorId Author {\n    #onDelete cascade\n  }\n" ++
        "  *!bookId Book\n  position int(0) {\n    #index\n    ? position >= 0\n  }\n" ++
        "  ?? position >= 0\n  ?? unique(authorId, bookId)\n  #index bookId\n}\n" ++
        "Author {\n  !id int\n}\nBook {\n  !id int\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const table = syntax.schema.schema.tables[0];
    try std.testing.expectEqualStrings("Authorship", table.name.text);
    try borrowed(source, table.name);
    try std.testing.expectEqualStrings("Credits\nStored explicitly", table.documentation.?.text);
    try std.testing.expectEqualStrings("~Authorship(Author, Book)", source[table.connection.?.span.start..table.connection.?.span.end]);
    try std.testing.expectEqualStrings("~Authorship(Author, Book) {", source[table.span.start .. table.span.start + "~Authorship(Author, Book) {".len]);
    try std.testing.expectEqual(@as(usize, 2), table.connection.?.endpoints.len);
    for (table.connection.?.endpoints) |endpoint| {
        try borrowed(source, endpoint.table);
        try std.testing.expect(endpoint.role == null);
        try std.testing.expectEqualDeep(endpoint.table.span, endpoint.span);
    }
    try std.testing.expectEqual(@as(usize, 3), table.fields.len);
    for (table.fields[0..2]) |field| {
        try std.testing.expect(field.primary_key and field.foreign_key);
        try std.testing.expect(!field.type.nullable);
    }
    try std.testing.expectEqualStrings("Author key", table.fields[0].documentation.?.text);
    try std.testing.expectEqualStrings("cascade", table.fields[0].directives[0].kind.on_delete.text);
    try std.testing.expectEqualStrings("0", table.fields[2].default.?.integer.text);
    try std.testing.expectEqual(@as(usize, 2), table.fields[2].directives.len);
    try std.testing.expectEqual(@as(usize, 4), table.directives.len);
    try std.testing.expect(syntax.schema.schema.tables[1].connection == null);

    const semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(resolver.Category.unsupported_feature, semantic.diagnostic.category);
    try std.testing.expectEqualDeep(table.connection.?.span, semantic.diagnostic.span);
    try std.testing.expectEqualStrings("Named connection resolution is not yet supported", semantic.diagnostic.message);
}

test "connection roles self endpoints mixtures and grouping trivia preserve exact spans" {
    const sources = [_][]const u8{
        "~Following(follower Reader, followed Reader) {}",
        "~Permission(user User, Resource, role Role) {}",
        "~Following(\n-- first\nfollower\nReader, -- next\n followed Reader\n) {}",
    };
    for (sources) |source| {
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        const table = syntax.schema.schema.tables[0];
        try std.testing.expectEqualStrings(source, source[table.span.start..table.span.end]);
        const endpoints = table.connection.?.endpoints;
        try std.testing.expect(endpoints.len >= 2);
        for (endpoints) |endpoint| {
            try borrowed(source, endpoint.table);
            if (endpoint.role) |role| {
                try borrowed(source, role);
                try std.testing.expectEqual(role.span.start, endpoint.span.start);
            } else try std.testing.expectEqual(endpoint.table.span.start, endpoint.span.start);
            try std.testing.expectEqual(endpoint.table.span.end, endpoint.span.end);
        }
        try std.testing.expectEqualStrings(if (endpoints.len == 2) "follower" else "user", endpoints[0].role.?.text);
        if (endpoints.len == 3) try std.testing.expect(endpoints[1].role == null);
        try std.testing.expectEqual(@as(usize, 0), table.fields.len); // No implicit keys.
    }
}

test "invalid connection headers and unsupported forms have exact diagnostic spans" {
    const Case = struct { source: []const u8, fragment: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .source = "~C() {}", .fragment = ")", .message = "Expected a declaration name" },
        .{ .source = "~C(A) {}", .fragment = ")", .message = "at least two endpoints" },
        .{ .source = "~C(A,) {}", .fragment = ")", .message = "Expected a declaration name" },
        .{ .source = "~C(A,, B) {}", .fragment = ",", .message = "Expected a declaration name" },
        .{ .source = "~C(,A, B) {}", .fragment = ",", .message = "Expected a declaration name" },
        .{ .source = "~C(A B C, D) {}", .fragment = "C", .message = "Expected ',' or ')'" },
        .{ .source = "~C(A, B, C,) {}", .fragment = ")", .message = "Expected a declaration name" },
        .{ .source = "~C(A,", .fragment = "", .message = "Expected a declaration name" },
        .{ .source = "~C(A, B", .fragment = "", .message = "Expected ',' or ')'" },
        .{ .source = "~C(A, B)", .fragment = "", .message = "Expected '{'" },
        .{ .source = "~C(A, B) {\n", .fragment = "", .message = "Expected '}'" },
        .{ .source = "~C(A,\n--- Nope\nB) {}", .fragment = "--- Nope", .message = "Expected a declaration name" },
        .{ .source = "~C(A, B) {\n~~\n}", .fragment = "~~", .message = "Generated connection keys not yet supported" },
        .{ .source = "T {\n~~\n}", .fragment = "~~", .message = "Generated connection keys not yet supported" },
        .{ .source = "~~", .fragment = "~~", .message = "Generated connection keys not yet supported" },
        .{ .source = "~(A, B) {}", .fragment = "~(", .message = "Unnamed connection table" },
        .{ .source = "~C(A, B) {\n~bs B[] @B.a\n}", .fragment = "~", .message = "Virtual relationships inside connection" },
        .{ .source = "~C(A, B) { *!a A *!b B }", .fragment = "*", .message = "Expected end of line" },
    };
    for (cases) |case| {
        var syntax = try parser.parse(std.testing.allocator, case.source);
        if (syntax == .schema) {
            syntax.schema.deinit();
            return error.ExpectedDiagnostic;
        }
        const diagnostic = syntax.diagnostic;
        try std.testing.expectEqualStrings(case.fragment, case.source[diagnostic.span.start..diagnostic.span.end]);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, case.message) != null);
        if (case.fragment.len == 0) try std.testing.expectEqual(case.source.len, diagnostic.span.start);
    }
}

fn allocatedConnections(allocator: std.mem.Allocator) !void {
    // Arena payload remains usable across unrelated parses; tokens still borrow source.
    const source = "--- Joined\n--- docs\n~C(a A, B, c C) {\n*!a A\n*!b B\n*!c C\n}\n";
    var first = try parser.parse(allocator, source);
    try std.testing.expect(first == .schema);
    defer first.schema.deinit();
    var other = try parser.parse(allocator, "T {}\n");
    try std.testing.expect(other == .schema);
    other.schema.deinit();
    const table = first.schema.schema.tables[0];
    try std.testing.expectEqualStrings("Joined\ndocs", table.documentation.?.text);
    try std.testing.expectEqual(@as(usize, 3), table.connection.?.endpoints.len);
    try borrowed(source, table.connection.?.endpoints[2].role.?);
    const semantic = try resolver.resolve(allocator, first.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(resolver.Category.unsupported_feature, semantic.diagnostic.category);
    var invalid = try parser.parse(allocator, "--- Docs\n~Bad(a A, B) {\n*!a A\n~~\n}\n");
    if (invalid == .schema) {
        invalid.schema.deinit();
        return error.ExpectedDiagnostic;
    }
    try std.testing.expectEqualStrings("Generated connection keys not yet supported", invalid.diagnostic.message);
}

test "resolver rejects connection metadata before unrelated type resolution" {
    var syntax = try parser.parse(std.testing.allocator, "Ordinary {\nvalue Unknown\n}\n~C(A, B) {}\n");
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqual(resolver.Category.unsupported_feature, semantic.diagnostic.category);
    try std.testing.expectEqualDeep(syntax.schema.schema.tables[1].connection.?.span, semantic.diagnostic.span);
}

test "connection arrays docs and failed resolution clean up at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatedConnections, .{});
}
