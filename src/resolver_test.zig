const std = @import("std");
const parsed = @import("model/parsed.zig");
const resolver = @import("resolver.zig");
const emitter = @import("emitter.zig");

const span: parsed.Span = .{ .start = 17, .end = 29 };
fn token(text: []const u8) parsed.Token {
    return .{ .text = text, .span = span };
}
fn field(name: []const u8, type_name: []const u8) parsed.Field {
    return .{ .name = token(name), .type = .{ .name = token(type_name), .span = span }, .span = span };
}
fn table(name: []const u8, fields: []const parsed.Field) parsed.Table {
    return .{ .name = token(name), .fields = fields, .span = span };
}
fn expectDiagnostic(input: parsed.Schema, category: resolver.Category, expected_span: parsed.Span) !void {
    var result = try resolver.resolve(std.testing.allocator, input);
    switch (result) {
        .schema => |*owned| {
            owned.deinit();
            return error.ExpectedDiagnostic;
        },
        .diagnostic => |diagnostic| {
            try std.testing.expectEqual(category, diagnostic.category);
            try std.testing.expectEqual(expected_span, diagnostic.span);
            try std.testing.expect(diagnostic.message.len > 0);
        },
    }
}

test "parsed to resolved to SQL fixture covers builtins naming defaults and reuse" {
    var id = field("id", "int");
    id.primary_key = true;
    id.directives = &.{.{ .kind = .allow_reuse, .span = span }};
    var title = field("URLValue", "text");
    title.default = .{ .text = token("'It''s C:\\books'") };
    var raw = field("rawText", "text");
    raw.default = .{ .text = token("##'This contains '# and \\ literally'##") };
    var real = field("ratio", "real");
    real.default = .{ .real = token("001.250") };
    var whole = field("whole", "real");
    whole.default = .{ .integer = token("+002") };
    var blob = field("payload", "blob");
    blob.default = .{ .raw_sql = token("`X'00FF'`") };
    var optional = field("optional", "text");
    optional.type.nullable = true;
    optional.default = .{ .null_value = token("null") };
    var exact = field("exact", "int");
    exact.directives = &.{.{ .kind = .{ .name = token("`Writer\"ID`") }, .span = span }};
    exact.default = .{ .integer = token("-007") };
    var named = table("Other", &.{field("value", "blob")});
    named.directives = &.{.{ .kind = .{ .name = token("`Exact Table`") }, .span = span }};
    var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{
        table("HTTPServer", &.{ id, title, raw, real, whole, blob, optional, exact }), named,
    } });
    try std.testing.expect(result == .schema);
    defer result.schema.deinit();
    const output_schema = result.schema.schema;
    try std.testing.expectEqualStrings("http_server", output_schema.tables[0].sql_name);
    try std.testing.expectEqualStrings("url_value", output_schema.tables[0].columns[1].sql_name);
    try std.testing.expectEqualStrings("URLValue", output_schema.tables[0].columns[1].dsl_name);
    try std.testing.expectEqual(.allow_reuse, output_schema.tables[0].columns[0].primary_key);
    try std.testing.expectEqualStrings("It's C:\\books", output_schema.tables[0].columns[1].default.?.text);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try emitter.emit(output_schema, &output.writer);
    try std.testing.expectEqualStrings(@embedFile("testdata/resolver/subset.expect.sql"), output.written());
}

test "snake conversion acronym boundaries and normal camel Pascal names" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "HTTPServer", .expected = "http_server" },
        .{ .input = "URLValue", .expected = "url_value" },
        .{ .input = "tenantId", .expected = "tenant_id" },
        .{ .input = "Invoice", .expected = "invoice" },
        .{ .input = "HTTP", .expected = "http" },
        .{ .input = "already_snake", .expected = "already_snake" },
        .{ .input = "version2Value", .expected = "version2_value" },
    };
    for (cases) |case| {
        var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{table(case.input, &.{})} });
        defer result.schema.deinit();
        try std.testing.expectEqualStrings(case.expected, result.schema.schema.tables[0].sql_name);
    }
}

test "unknown builtin aliases and unmodeled reusable references report type token span" {
    for ([_][]const u8{ "Money", "bool", "datetime", "string", "Int", "text[]" }) |name| {
        var f = field("value", name);
        f.type.name.span = .{ .start = 40, .end = 45 };
        try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .unknown_type, f.type.name.span);
    }
}

test "duplicates and ASCII SQL collisions in table and per-table column namespaces" {
    try expectDiagnostic(.{ .tables = &.{ table("Same", &.{}), table("Same", &.{}) } }, .duplicate_dsl_name, span);
    try expectDiagnostic(.{ .tables = &.{table("T", &.{ field("same", "int"), field("same", "blob") })} }, .duplicate_dsl_name, span);
    try expectDiagnostic(.{ .tables = &.{ table("HTTPServer", &.{}), table("http_server", &.{}) } }, .sql_name_collision, span);
    try expectDiagnostic(.{ .tables = &.{table("T", &.{ field("tenantId", "int"), field("tenant_id", "int") })} }, .sql_name_collision, span);
    for ([_]bool{ false, true }) |at_table| {
        var first = field("a", "int");
        first.directives = &.{.{ .kind = .{ .name = token("`WriterID`") }, .span = span }};
        var second = field("b", "int");
        second.directives = &.{.{ .kind = .{ .name = token("`writerid`") }, .span = span }};
        var a = table("A", &.{first});
        var b = table("B", &.{second});
        if (at_table) {
            a.directives = first.directives;
            b.directives = second.directives;
            try expectDiagnostic(.{ .tables = &.{ a, b } }, .sql_name_collision, span);
        } else {
            try expectDiagnostic(.{ .tables = &.{table("A", &.{ first, second })} }, .sql_name_collision, span);
        }
    }
    var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{ table("A", &.{field("same", "int")}), table("B", &.{field("same", "int")}) } });
    defer result.schema.deinit();
}

test "directive duplication scopes and safe exact-name delimiters" {
    const name: parsed.Directive = .{ .kind = .{ .name = token("`exact`") }, .span = span };
    const reuse: parsed.Directive = .{ .kind = .allow_reuse, .span = span };
    for ([_]bool{ false, true }) |at_table| {
        var f = field("id", "int");
        var t = table("T", &.{});
        if (at_table) t.directives = &.{ name, name } else f.directives = &.{ name, name };
        t.fields = &.{f};
        try expectDiagnostic(.{ .tables = &.{t} }, .duplicate_directive, span);
    }
    var f = field("id", "int");
    f.directives = &.{ reuse, reuse };
    try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .duplicate_directive, span);
    var t = table("T", &.{});
    t.directives = &.{reuse};
    try expectDiagnostic(.{ .tables = &.{t} }, .invalid_directive_scope, span);
    for ([_][]const u8{ "plain", "'name'", "`", "`a`b`", "`a``b`" }) |invalid| {
        f.directives = &.{.{ .kind = .{ .name = token(invalid) }, .span = span }};
        try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .invalid_literal, span);
    }
    for ([_][]const u8{ "``", "`a\x00b`" }) |invalid| {
        f.directives = &.{.{ .kind = .{ .name = token(invalid) }, .span = span }};
        try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .invalid_identifier, span);
    }
    try expectDiagnostic(.{ .tables = &.{table("", &.{})} }, .invalid_identifier, span);
    try expectDiagnostic(.{ .tables = &.{table("T", &.{field("a\x00b", "int")})} }, .invalid_identifier, span);
}

test "primary-key validation including composite policy" {
    var f = field("id", "int");
    f.primary_key = true;
    f.type.nullable = true;
    try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .nullable_primary_key, span);
    f.type.nullable = false;
    f.default = .{ .integer = token("1") };
    for ([_]bool{ false, true }) |reuse| {
        f.directives = if (reuse) &.{.{ .kind = .allow_reuse, .span = span }} else &.{};
        try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .default_on_auto_primary_key, span);
    }
    f.default = null;
    for ([_][]const u8{ "real", "text", "blob" }) |name| {
        f.type.name = token(name);
        try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .invalid_id_reuse, span);
    }
    f.type.name = token("int");
    f.primary_key = false;
    try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, .invalid_id_reuse, span);
    f.primary_key = true;
    var other = field("other", "int");
    other.primary_key = true;
    try expectDiagnostic(.{ .tables = &.{table("T", &.{ f, other })} }, .invalid_id_reuse, span);
    f.directives = &.{};
    f.default = .{ .integer = token("1") };
    var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{table("T", &.{ f, other })} });
    defer result.schema.deinit();
    try std.testing.expectEqual(.standard, result.schema.schema.tables[0].columns[0].primary_key);
}

test "literal decoding mismatches malformed delimiters overflow and unsupported multiline" {
    const Case = struct { type_name: []const u8, default: parsed.Default, category: resolver.Category };
    const cases = [_]Case{
        .{ .type_name = "int", .default = .{ .text = token("'1'") }, .category = .invalid_default },
        .{ .type_name = "int", .default = .{ .real = token("1.0") }, .category = .invalid_default },
        .{ .type_name = "text", .default = .{ .integer = token("1") }, .category = .invalid_default },
        .{ .type_name = "blob", .default = .{ .text = token("'bytes'") }, .category = .invalid_default },
        .{ .type_name = "text", .default = .{ .null_value = token("null") }, .category = .invalid_default },
        .{ .type_name = "int", .default = .{ .integer = token("9223372036854775808") }, .category = .invalid_literal },
        .{ .type_name = "int", .default = .{ .integer = token("oops") }, .category = .invalid_literal },
        .{ .type_name = "real", .default = .{ .real = token("1e9999") }, .category = .invalid_literal },
        .{ .type_name = "real", .default = .{ .real = token("nan") }, .category = .invalid_literal },
        .{ .type_name = "real", .default = .{ .real = token("oops") }, .category = .invalid_literal },
        .{ .type_name = "text", .default = .{ .text = token("'it's'") }, .category = .invalid_literal },
        .{ .type_name = "text", .default = .{ .text = token("\"text\"") }, .category = .invalid_literal },
        .{ .type_name = "text", .default = .{ .text = token("'") }, .category = .invalid_literal },
        .{ .type_name = "text", .default = .{ .text = token("##'mismatch'#") }, .category = .invalid_literal },
        .{ .type_name = "text", .default = .{ .text = token("#'early'#close'#") }, .category = .invalid_literal },
        .{ .type_name = "text", .default = .{ .text = token("#'''x'''#") }, .category = .unsupported_multiline },
        .{ .type_name = "text", .default = .{ .text = token("#'a\nb'#") }, .category = .unsupported_multiline },
        .{ .type_name = "text", .default = .{ .text = token("'a\nb'") }, .category = .unsupported_multiline },
        .{ .type_name = "blob", .default = .{ .raw_sql = token("``") }, .category = .invalid_literal },
        .{ .type_name = "blob", .default = .{ .raw_sql = token("`a`b`") }, .category = .invalid_literal },
        .{ .type_name = "blob", .default = .{ .raw_sql = token("`a\x00b`") }, .category = .invalid_literal },
    };
    for (cases) |case| {
        var f = field("value", case.type_name);
        f.default = case.default;
        try expectDiagnostic(.{ .tables = &.{table("T", &.{f})} }, case.category, span);
    }
    for ([_][]const u8{ "''", "#''#", "##''##", "'\\n'", "'a\x00b'" }, [_][]const u8{ "", "", "", "\\n", "a\x00b" }) |input, expected| {
        var f = field("value", "text");
        f.default = .{ .text = token(input) };
        var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{table("T", &.{f})} });
        defer result.schema.deinit();
        try std.testing.expectEqualStrings(expected, result.schema.schema.tables[0].columns[0].default.?.text);
    }
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var f = field("URLValue", "text");
    f.default = .{ .text = token("'it''s literal'") };
    var result = try resolver.resolve(allocator, .{ .tables = &.{table("HTTPServer", &.{f})} });
    defer result.schema.deinit();
    var invalid = field("bad", "Unknown");
    invalid.default = null;
    const failure = try resolver.resolve(allocator, .{ .tables = &.{table("HTTPServer", &.{ f, invalid })} });
    try std.testing.expect(failure == .diagnostic);
}

test "allocation failures and semantic failures release partial owned state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "resolved schema owns source strings and empty schemas" {
    var source = [_]u8{ 'N', 'a', 'm', 'e' };
    var result = try resolver.resolve(std.testing.allocator, .{ .tables = &.{table(&source, &.{})} });
    defer result.schema.deinit();
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("Name", result.schema.schema.tables[0].dsl_name);
    try std.testing.expectEqualStrings("name", result.schema.schema.tables[0].sql_name);
    var empty = try resolver.resolve(std.testing.allocator, .{});
    defer empty.schema.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.schema.schema.tables.len);
}
