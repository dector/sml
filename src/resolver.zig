//! Semantic resolution of the modeled subset (no reusable types yet).
//! `resolve` returns either an owned schema or the first source-span diagnostic.
//! Allocator failures are returned separately as OutOfMemory. Success owns all
//! arrays and strings, does not borrow parsed input, and must be deinitialized.
//! All allocations are reclaimed on semantic or allocation failure.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");

pub const Category = enum {
    unknown_type,
    invalid_identifier,
    duplicate_dsl_name,
    sql_name_collision,
    duplicate_directive,
    invalid_directive_scope,
    invalid_id_reuse,
    nullable_primary_key,
    invalid_primary_key,
    default_on_auto_primary_key,
    invalid_default,
    invalid_literal,
    unsupported_multiline,
};

pub const Diagnostic = struct {
    category: Category,
    span: parsed.Span,
    message: []const u8,
};

pub const OwnedSchema = struct {
    schema: resolved.Schema,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *OwnedSchema) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    schema: OwnedSchema,
    diagnostic: Diagnostic,
};

pub fn resolve(allocator: std.mem.Allocator, input: parsed.Schema) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var context: Context = .{ .allocator = arena.allocator() };
    const schema = context.schema(input) catch |err| switch (err) {
        error.SemanticFailure => {
            arena.deinit();
            return .{ .diagnostic = context.diagnostic.? };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .schema = .{ .schema = schema, .arena = arena } };
}

const Error = std.mem.Allocator.Error || error{SemanticFailure};
const Options = struct { name: ?parsed.Token = null, reuse: ?parsed.Span = null };
const Context = struct {
    allocator: std.mem.Allocator,
    diagnostic: ?Diagnostic = null,

    fn fail(self: *Context, category: Category, span: parsed.Span, message: []const u8) Error {
        self.diagnostic = .{ .category = category, .span = span, .message = message };
        return error.SemanticFailure;
    }

    fn options(self: *Context, directives: []const parsed.Directive, table: bool) Error!Options {
        var result: Options = .{};
        for (directives) |directive| switch (directive.kind) {
            .name => |token| {
                if (result.name != null) return self.fail(.duplicate_directive, directive.span, "duplicate #name directive");
                result.name = token;
            },
            .allow_reuse => {
                if (result.reuse != null) return self.fail(.duplicate_directive, directive.span, "duplicate #allow reuse directive");
                if (table) return self.fail(.invalid_directive_scope, directive.span, "#allow reuse is field-only");
                result.reuse = directive.span;
            },
        };
        return result;
    }

    fn backticks(self: *Context, token: parsed.Token) Error![]const u8 {
        const text = token.text;
        if (std.mem.indexOfAny(u8, text, "\r\n") != null)
            return self.fail(.unsupported_multiline, token.span, "multiline backticks are not supported yet");
        var hashes: usize = 0;
        while (hashes < text.len and text[hashes] == '#') : (hashes += 1) {}
        if (text.len < 2 * hashes + 2 or text[hashes] != '`')
            return self.fail(.invalid_literal, token.span, "expected matching backtick delimiters");
        const start = hashes + 1;
        var i = start;
        while (i < text.len) : (i += 1) {
            if (text[i] != '`') continue;
            var end = i + 1;
            while (end < text.len and text[end] == '#') : (end += 1) {}
            if (hashes == 0) end = i + 1 else if (end - i - 1 != hashes) continue;
            if (end != text.len)
                return self.fail(.invalid_literal, token.span, "backtick literal contains its closing delimiter");
            return text[start..i];
        }
        return self.fail(.invalid_literal, token.span, "expected matching backtick delimiters");
    }

    fn name(self: *Context, token: parsed.Token, override: ?parsed.Token) Error![]const u8 {
        if (override) |exact| {
            const text = try self.backticks(exact);
            if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null)
                return self.fail(.invalid_identifier, exact.span, "SQL identifier must be nonempty and contain no NUL");
            return self.allocator.dupe(u8, text);
        }
        if (token.text.len == 0 or std.mem.indexOfScalar(u8, token.text, 0) != null)
            return self.fail(.invalid_identifier, token.span, "identifier must be nonempty and contain no NUL");
        var output: std.ArrayList(u8) = .empty;
        for (token.text, 0..) |byte, i| {
            if (std.ascii.isUpper(byte) and i > 0) {
                const prev = token.text[i - 1];
                const boundary = std.ascii.isLower(prev) or std.ascii.isDigit(prev) or
                    (std.ascii.isUpper(prev) and i + 1 < token.text.len and std.ascii.isLower(token.text[i + 1]));
                if (boundary) try output.append(self.allocator, '_');
            }
            try output.append(self.allocator, std.ascii.toLower(byte));
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn schema(self: *Context, input: parsed.Schema) Error!resolved.Schema {
        const tables = try self.allocator.alloc(resolved.Table, input.tables.len);
        for (input.tables, 0..) |table, i| {
            for (input.tables[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name.text, table.name.text))
                    return self.fail(.duplicate_dsl_name, table.name.span, "duplicate DSL table name");
            }
            const opts = try self.options(table.directives, true);
            const sql_name = try self.name(table.name, opts.name);
            for (tables[0..i]) |previous| {
                if (std.ascii.eqlIgnoreCase(previous.sql_name, sql_name))
                    return self.fail(.sql_name_collision, if (opts.name) |n| n.span else table.name.span, "SQL table names collide (ASCII case-insensitive)");
            }
            var key_count: usize = 0;
            for (table.fields) |field| {
                if (field.primary_key) key_count += 1;
            }
            const columns = try self.allocator.alloc(resolved.Column, table.fields.len);
            for (table.fields, 0..) |field, j| {
                for (table.fields[0..j]) |previous| {
                    if (std.mem.eql(u8, previous.name.text, field.name.text))
                        return self.fail(.duplicate_dsl_name, field.name.span, "duplicate DSL field name");
                }
                const field_opts = try self.options(field.directives, false);
                const column_name = try self.name(field.name, field_opts.name);
                for (columns[0..j]) |previous| {
                    if (std.ascii.eqlIgnoreCase(previous.sql_name, column_name))
                        return self.fail(.sql_name_collision, if (field_opts.name) |n| n.span else field.name.span, "SQL column names collide (ASCII case-insensitive)");
                }
                const storage: resolved.StorageType = if (std.mem.eql(u8, field.type.name.text, "int")) .integer else if (std.mem.eql(u8, field.type.name.text, "real")) .real else if (std.mem.eql(u8, field.type.name.text, "str")) .text else if (std.mem.eql(u8, field.type.name.text, "blob")) .blob else if (std.mem.eql(u8, field.type.name.text, "bool")) .boolean else if (std.mem.eql(u8, field.type.name.text, "datetime")) .datetime else return self.fail(.unknown_type, field.type.name.span, "unknown type; supported builtins are int, real, str, blob, bool, datetime");
                if (field.primary_key and field.type.nullable)
                    return self.fail(.nullable_primary_key, field.type.span, "primary-key fields cannot be nullable");
                if (field.primary_key and storage == .boolean)
                    return self.fail(.invalid_primary_key, field.type.name.span, "Boolean fields cannot be primary keys (including composite keys)");
                if (field_opts.reuse) |span| {
                    if (!field.primary_key or storage != .integer or key_count != 1)
                        return self.fail(.invalid_id_reuse, span, "#allow reuse requires a single integer primary key");
                }
                var value: ?resolved.Default = null;
                if (field.default) |default| {
                    const token = defaultToken(default);
                    if (field.primary_key and storage == .integer and key_count == 1)
                        return self.fail(.default_on_auto_primary_key, token.span, "auto-generated integer primary keys cannot have defaults");
                    value = try self.defaultValue(default, storage, field.type.nullable);
                }
                columns[j] = .{
                    .dsl_name = try self.allocator.dupe(u8, field.name.text),
                    .sql_name = column_name,
                    .type = storage,
                    .nullable = field.type.nullable,
                    .primary_key = if (field_opts.reuse != null) .allow_reuse else if (field.primary_key) .standard else .none,
                    .default = value,
                    .documentation = try self.documentation(field.documentation),
                };
            }
            tables[i] = .{ .dsl_name = try self.allocator.dupe(u8, table.name.text), .sql_name = sql_name, .columns = columns, .documentation = try self.documentation(table.documentation) };
        }
        return .{ .tables = tables };
    }

    fn documentation(self: *Context, docs: ?parsed.Documentation) Error!?resolved.Documentation {
        const value = docs orelse return null;
        return .{ .text = try self.allocator.dupe(u8, value.text), .span = value.span };
    }

    fn defaultValue(self: *Context, value: parsed.Default, storage: resolved.StorageType, nullable: bool) Error!resolved.Default {
        const token = defaultToken(value);
        const compatible = switch (value) {
            .integer => storage == .integer or storage == .real,
            .boolean => storage == .boolean,
            .real => storage == .real,
            .text => storage == .text or storage == .datetime,
            .generator => storage == .datetime,
            .null_value => nullable,
            .raw_sql => true,
        };
        if (!compatible) return self.fail(.invalid_default, token.span, "default does not match column type or nullability");
        return switch (value) {
            .boolean => blk: {
                if (std.mem.eql(u8, token.text, "true")) break :blk .{ .boolean = true };
                if (std.mem.eql(u8, token.text, "false")) break :blk .{ .boolean = false };
                return self.fail(.invalid_literal, token.span, "expected true or false literal");
            },
            .integer => .{ .integer = std.fmt.parseInt(i64, token.text, 10) catch
                return self.fail(.invalid_literal, token.span, "invalid or out-of-range integer literal") },
            .real => blk: {
                const number = std.fmt.parseFloat(f64, token.text) catch
                    return self.fail(.invalid_literal, token.span, "invalid real literal");
                if (!std.math.isFinite(number)) return self.fail(.invalid_literal, token.span, "real literal must be finite");
                break :blk .{ .real = number };
            },
            .text => blk: {
                const text = try self.string(token);
                if (storage == .datetime) {
                    if (!@import("datetime.zig").valid(text))
                        return self.fail(.invalid_literal, token.span, "datetime requires a real UTC date in YYYY-MM-DDTHH:MM:SSZ format (years 0001-9999)");
                    break :blk .{ .datetime = text };
                }
                break :blk .{ .text = text };
            },
            .generator => blk: {
                if (!std.mem.eql(u8, token.text, "::now"))
                    return self.fail(.invalid_literal, token.span, "unsupported generator; only ::now is supported");
                break :blk .now;
            },
            .null_value => blk: {
                if (!std.mem.eql(u8, token.text, "null")) return self.fail(.invalid_literal, token.span, "expected null literal");
                break :blk .null_value;
            },
            .raw_sql => blk: {
                const sql = try self.backticks(token);
                if (sql.len == 0 or std.mem.indexOfScalar(u8, sql, 0) != null)
                    return self.fail(.invalid_literal, token.span, "raw SQL must be nonempty and contain no NUL");
                break :blk .{ .raw_sql = try self.allocator.dupe(u8, sql) };
            },
        };
    }

    fn string(self: *Context, token: parsed.Token) Error![]const u8 {
        const text = token.text;
        if (std.mem.indexOfAny(u8, text, "\r\n") != null)
            return self.fail(.unsupported_multiline, token.span, "multiline string decoding is not supported yet");
        var hashes: usize = 0;
        while (hashes < text.len and text[hashes] == '#') : (hashes += 1) {}
        if (hashes > 0) {
            if (std.mem.startsWith(u8, text[hashes..], "'''"))
                return self.fail(.unsupported_multiline, token.span, "multiline raw string decoding is not supported yet");
            if (text.len < 2 * hashes + 2 or text[hashes] != '\'' or
                text[text.len - hashes - 1] != '\'' or !std.mem.eql(u8, text[0..hashes], text[text.len - hashes ..]))
                return self.fail(.invalid_literal, token.span, "raw string requires matching hash delimiters");
            const content_end = text.len - hashes - 1;
            var i = hashes + 1;
            while (i < text.len) : (i += 1) {
                if (text[i] != '\'') continue;
                var end = i + 1;
                while (end < text.len and text[end] == '#') : (end += 1) {}
                if (end - i - 1 != hashes) continue;
                if (i != content_end or end != text.len)
                    return self.fail(.invalid_literal, token.span, "raw string contains its closing delimiter");
                return self.allocator.dupe(u8, text[hashes + 1 .. i]);
            }
            return self.fail(.invalid_literal, token.span, "raw string requires matching hash delimiters");
        }
        if (text.len < 2 or text[0] != '\'' or text[text.len - 1] != '\'')
            return self.fail(.invalid_literal, token.span, "text requires single-quote or hash delimiters");
        var output: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < text.len - 1) : (i += 1) {
            if (text[i] == '\'') {
                if (i + 1 >= text.len - 1 or text[i + 1] != '\'')
                    return self.fail(.invalid_literal, token.span, "embedded single quotes must be doubled");
                i += 1;
            }
            try output.append(self.allocator, text[i]);
        }
        return output.toOwnedSlice(self.allocator);
    }
};

test {
    _ = @import("resolver_test.zig");
}

fn defaultToken(value: parsed.Default) parsed.Token {
    return switch (value) {
        inline else => |token| token,
    };
}
