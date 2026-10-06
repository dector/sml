const std = @import("std");
const parser = @import("parser.zig");
const parsed = @import("model/parsed.zig");
const resolver = @import("resolver.zig");
const tokenizer = @import("tokenizer.zig");

fn diagnostic(source: []const u8) !parsed.Diagnostic {
    var result = try parser.parse(std.testing.allocator, source);
    if (result == .schema) {
        result.schema.deinit();
        return error.ExpectedDiagnostic;
    }
    try std.testing.expect(result.diagnostic.span.end <= source.len);
    return result.diagnostic;
}

fn borrowed(source: []const u8, token: parsed.Token) !void {
    try std.testing.expectEqualStrings(token.text, source[token.span.start..token.span.end]);
    try std.testing.expectEqual(@intFromPtr(source.ptr) + token.span.start, @intFromPtr(token.text.ptr));
}

test "relationship punctuation preserves exact delimiters borrowed spans and repeated EOF" {
    const source = "~books Book[]@Book.owner";
    var lexer = tokenizer.Tokenizer.init(source);
    const kinds = [_]tokenizer.Kind{ .tilde, .identifier, .identifier, .l_bracket, .r_bracket, .at, .identifier, .dot, .identifier, .eof, .eof };
    const texts = [_][]const u8{ "~", "books", "Book", "[", "]", "@", "Book", ".", "owner", "", "" };
    for (kinds, texts) |kind, text| {
        const result = lexer.next();
        try std.testing.expect(result == .token);
        try std.testing.expectEqual(kind, result.token.kind);
        try std.testing.expectEqualStrings(text, result.token.text);
        try borrowed(source, .{ .text = result.token.text, .span = result.token.span });
    }
    var number = tokenizer.Tokenizer.init(".5");
    const result = number.next();
    try std.testing.expect(result == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, "number syntax") != null);
    const expression = @import("expression_parser.zig");
    const dotted = try expression.parse(std.testing.allocator, "Author.name");
    try std.testing.expect(dotted == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, dotted.diagnostic.message, "trailing") != null);
    try std.testing.expectEqualDeep(parsed.Span{ .start = 6, .end = 7 }, dotted.diagnostic.span);
}

test "direct relationships preserve names cardinality full spans docs and separate source order" {
    const source = "--- Table\nShelf {\n  --- Collection\n  -- attached\n  ~Books_2 Book[]@Book.owner_2 -- trailing\n  --- Stored\n  id int\n  --- Singular\n  ~book Book? @Book._owner\n  ~required Book @Book.owner\n  ~Books_2 Book[] @Book.owner\n  #name `shelf`\n}\n";
    var syntax = try parser.parse(std.testing.allocator, source);
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    const table = syntax.schema.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 1), table.fields.len);
    try std.testing.expectEqual(@as(usize, 4), table.relationships.len);
    try std.testing.expectEqualStrings("Table", table.documentation.?.text);
    try std.testing.expectEqualStrings("Stored", table.fields[0].documentation.?.text);
    const collection = table.relationships[0];
    try std.testing.expectEqualStrings("Books_2", collection.name.text);
    try std.testing.expectEqualStrings("Collection", collection.documentation.?.text);
    try std.testing.expect(collection.collection and !collection.target.nullable);
    try std.testing.expectEqualStrings("Book[]", source[collection.target.span.start..collection.target.span.end]);
    try std.testing.expectEqualStrings("~Books_2 Book[]@Book.owner_2", source[collection.span.start..collection.span.end]);
    const singular = table.relationships[1];
    try std.testing.expect(!singular.collection and singular.target.nullable);
    try std.testing.expectEqualStrings("Book?", source[singular.target.span.start..singular.target.span.end]);
    try std.testing.expectEqualStrings("Singular", singular.documentation.?.text);
    try std.testing.expectEqualStrings("_owner", singular.source_field.text);
    try std.testing.expect(!table.relationships[2].target.nullable);
    for (table.relationships) |relationship| {
        try borrowed(source, relationship.name);
        try borrowed(source, relationship.target.name);
        try borrowed(source, relationship.source_table);
        try borrowed(source, relationship.source_field);
    }
    // Duplicates and required singular cardinality are deferred, not silently dropped.
    const semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .diagnostic);
    try std.testing.expectEqualDeep(collection.span, semantic.diagnostic.span);
    try std.testing.expectEqual(.unsupported_feature, semantic.diagnostic.category);
}

test "relationship mapping and options have explicit diagnostics" {
    const cases = [_][2][]const u8{
        .{ "T {\n  ~books Book[]\n}\n", "require a direct @Table.field" },
        .{ "T {\n  ~books Book[] @.owner\n}\n", "Connection shorthand" },
        .{ "~Connection(A, B) {}", "Connection table" },
        .{ "~(A, B) {}", "Connection table" },
        .{ "T {\n  ~books Book[]? @Book.owner\n}", "cannot be nullable" },
        .{ "T {\n  books Book[]\n}", "Stored arrays" },
        .{ "T {\n  ~books Book[] (null) @Book.owner\n}", "cannot have defaults" },
        .{ "T {\n  ~books Book[] @Book.owner(null)\n}", "cannot have defaults" },
        .{ "T {\n  ~!books Book[] @Book.owner\n}", "markers" },
        .{ "T {\n  !~books Book[] @Book.owner\n}", "markers" },
        .{ "T {\n  *~books Book[] @Book.owner\n}", "markers" },
        .{ "T {\n  ~books Book[] @Book.owner!\n}", "markers" },
        .{ "T {\n  ~books Book[] @Book.owner {}\n}", "bodies" },
        .{ "T {\n  ~books Book[] @Book.owner =\n}", "bodies" },
        .{ "T {\n  ~books Book[] @Book.owner #name `x`\n}", "directives" },
        .{ "T {\n  ~books Book[] @Book.owner #index\n}", "directives" },
        .{ "T {\n  ~books Book[] @Book.owner #check true\n}", "directives" },
        .{ "T {\n  ~books Book[] @Book.owner ? unique\n}", "constraints" },
        .{ "T {\n  ~books Book[] @Book.owner\n    #unique\n}", "directives" },
        .{ "T {\n  ~books Book[] @Book.owner\n\n    -- comment\n    #index\n}", "directives" },
    };
    for (cases) |case| {
        const d = try diagnostic(case[0]);
        try std.testing.expect(std.mem.indexOf(u8, d.message, case[1]) != null);
    }
}

test "relationship names all use declaration identifier grammar" {
    for ([_][]const u8{ "_", "true", "false", "null", "1", "'x'", "`x`" }) |bad| {
        inline for ([_][]const u8{ "T {{\n  ~{s} Book[] @Book.owner\n}}", "T {{\n  ~books {s}[] @Book.owner\n}}", "T {{\n  ~books Book[] @{s}.owner\n}}", "T {{\n  ~books Book[] @Book.{s}\n}}" }) |format| {
            const source = try std.fmt.allocPrint(std.testing.allocator, format, .{bad});
            defer std.testing.allocator.free(source);
            _ = try diagnostic(source);
        }
    }
    for ([_][]const u8{ "T {\n  ~books Book[] @Book.owner.extra\n}", "T {\n  ~books Book[] @Book..owner\n}" }) |source| _ = try diagnostic(source);
}

test "every incomplete relationship prefix reports EOF without partial schemas" {
    const prefixes = [_][]const u8{ "~", "~books", "~books Book", "~books Book[", "~books Book[]", "~books Book?", "~books Book[] @", "~books Book[] @Book", "~books Book[] @Book.", "~books Book[] @Book.owner" };
    for (prefixes) |prefix| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "T {{\n  {s}", .{prefix});
        defer std.testing.allocator.free(source);
        const d = try diagnostic(source);
        try std.testing.expectEqualDeep(parsed.Span{ .start = source.len, .end = source.len }, d.span);
    }
}

test "relationship documentation obeys declaration attachment and scope rules" {
    for ([_][]const u8{
        "T {\n  --- docs\n\n  ~books Book[] @Book.owner\n}",
        "T {\n  ~books Book[] @Book.owner --- inline\n}",
        "T {\n  ~books Book[] @Book.owner\n  --- docs\n}",
        "T {\n  --- docs\n  #index owner\n}",
        "T {\n  --- docs",
        "T {\n  ~books Book[] @Book.owner\n    --- docs\n    #index\n}",
    }) |source| {
        const d = try diagnostic(source);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "documentation") != null or std.mem.indexOf(u8, d.message, "Documentation") != null);
    }
}

fn allocationCase(allocator: std.mem.Allocator, invalid: bool) !void {
    const source = "--- Table\nT {\n  --- First\n  --- Second\n  ~books Book[] @Book.owner\n  id int\n  ~book Book? @Book.owner\n";
    var result = try parser.parse(allocator, if (invalid) source else source ++ "}\n");
    if (invalid) {
        try std.testing.expect(result == .diagnostic);
    } else {
        try std.testing.expect(result == .schema);
        result.schema.deinit();
    }
}

test "relationship parsing releases all allocations on success diagnostic and OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{true});
}
