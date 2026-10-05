const std = @import("std");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");

test "source to SQL fixture covers supported parser milestone" {
    var syntax = try parser.parse(std.testing.allocator, @embedFile("testdata/parser/subset.pzl"));
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try emitter.emit(semantic.schema.schema, &sql.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/subset.expect.sql"), sql.written());
}

test "source docs fixture preserves attachment and is emitted safely" {
    var syntax = try parser.parse(std.testing.allocator, @embedFile("testdata/parser/documentation.pzl"));
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try emitter.emit(semantic.schema.schema, &sql.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/documentation.expect.sql"), sql.written());
}

test "raw strings keep nonmatching closing hash counts through resolution" {
    var syntax = try parser.parse(std.testing.allocator, "Item {\n  value str(##'x'###z'#y'##)\n}\n");
    try std.testing.expect(syntax == .schema);
    defer syntax.schema.deinit();
    var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    try std.testing.expectEqualStrings("x'###z'#y", semantic.schema.schema.tables[0].columns[0].default.?.text);
}

test "unknown names parse and fail in resolution including retired aliases" {
    for ([_][]const u8{ "Money", "text", "string" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "Item {{\n  value {s}\n}}\n", .{name});
        defer std.testing.allocator.free(source);
        var syntax = try parser.parse(std.testing.allocator, source);
        try std.testing.expect(syntax == .schema);
        defer syntax.schema.deinit();
        var semantic = try resolver.resolve(std.testing.allocator, syntax.schema.schema);
        switch (semantic) {
            .schema => |*owned| {
                owned.deinit();
                return error.ExpectedUnknownType;
            },
            .diagnostic => |diagnostic| {
                try std.testing.expectEqual(resolver.Category.unknown_type, diagnostic.category);
                try std.testing.expectEqualStrings(name, source[diagnostic.span.start..diagnostic.span.end]);
            },
        }
    }
}

test "unsupported later slices never produce a partial schema" {
    const sources = [_][]const u8{
        "=> Label str\n",
        "Label {\n  value bool(::now)\n}\n",
        "Label {\n  value int(::now)\n}\n",
        "Label {\n  value str =\n    #index {\n      #unique\n    }\n}\n",
        "Label {\n  *owner Owner\n}\n",
        "Label {\n  ~owners Owner[]\n}\n",
        "~Membership(Owner, Label) {}\n",
        "Label {\n  value str |\n    #name `value`\n}\n",
    };
    for (sources) |source| {
        var syntax = try parser.parse(std.testing.allocator, source);
        switch (syntax) {
            .schema => |*owned| {
                owned.deinit();
                return error.ExpectedUnsupportedSyntax;
            },
            .diagnostic => |diagnostic| {
                try std.testing.expect(diagnostic.message.len > 0);
                try std.testing.expect(diagnostic.span.start <= diagnostic.span.end);
                try std.testing.expect(diagnostic.span.end <= source.len);
            },
        }
    }
}

test "resolved schema survives freeing parsed arena and source" {
    const source = try std.testing.allocator.dupe(u8, "--- Table docs.\nItem {\n  --- Field docs.\n  value str(##'raw text'##) {\n    #name #`a`b`#\n  }\n}\n");
    var syntax = try parser.parse(std.testing.allocator, source);
    if (syntax != .schema) {
        std.testing.allocator.free(source);
        return error.ExpectedSchema;
    }
    var semantic = resolver.resolve(std.testing.allocator, syntax.schema.schema) catch |err| {
        syntax.schema.deinit();
        std.testing.allocator.free(source);
        return err;
    };
    syntax.schema.deinit();
    std.testing.allocator.free(source);
    try std.testing.expect(semantic == .schema);
    defer semantic.schema.deinit();
    var sql = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sql.deinit();
    try emitter.emit(semantic.schema.schema, &sql.writer);
    try std.testing.expect(std.mem.indexOf(u8, sql.written(), "-- Table docs.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql.written(), "-- Field docs.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql.written(), "\"a`b\" TEXT NOT NULL DEFAULT 'raw text'") != null);
}
