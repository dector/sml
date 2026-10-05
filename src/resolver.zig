//! Semantic resolution of the modeled subset (no reusable types yet).
//! `resolve` returns either an owned schema or the first source-span diagnostic.
//! Allocator failures are returned separately as OutOfMemory. Success owns all
//! arrays and strings, does not borrow parsed input, and must be deinitialized.
//! All allocations are reclaimed on semantic or allocation failure.
const std = @import("std");
const parsed = @import("model/parsed.zig");
const resolved = @import("model/resolved.zig");
const literals = @import("literal_decoder.zig");
const expression_resolver = @import("expression_resolver.zig");

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
    invalid_enum,
    unsupported_multiline,
    invalid_check,
    invalid_unique,
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

const Options = struct { name: ?parsed.Token = null, reuse: ?parsed.Span = null };
const Context = struct {
    pub const Error = std.mem.Allocator.Error || error{SemanticFailure};
    allocator: std.mem.Allocator,
    diagnostic: ?Diagnostic = null,

    pub fn fail(self: *Context, category: Category, span: parsed.Span, message: []const u8) Error {
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
            .check => {},
            .native_unique => {
                if (table) return self.fail(.invalid_directive_scope, directive.span, "Table composite uniqueness is unsupported; deferred");
            },
            .of => {
                if (table) return self.fail(.invalid_directive_scope, directive.span, "#of is field-only");
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
        return literals.backticks(self, token);
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
                const storage: resolved.StorageType = if (std.mem.eql(u8, field.type.name.text, "int")) .integer else if (std.mem.eql(u8, field.type.name.text, "real")) .real else if (std.mem.eql(u8, field.type.name.text, "str")) .text else if (std.mem.eql(u8, field.type.name.text, "blob")) .blob else if (std.mem.eql(u8, field.type.name.text, "bool")) .boolean else if (std.mem.eql(u8, field.type.name.text, "datetime")) .datetime else if (std.mem.eql(u8, field.type.name.text, "enum")) .enumeration else return self.fail(.unknown_type, field.type.name.span, "unknown type; supported builtins are int, real, str, blob, bool, datetime, enum");
                var enum_values: std.ArrayList([]const u8) = .empty;
                for (field.directives) |directive| {
                    if (directive.kind == .of) {
                        if (storage != .enumeration) return self.fail(.invalid_directive_scope, directive.span, "#of requires an enum field");
                        if (directive.kind.of.len == 0) return self.fail(.invalid_enum, directive.span, "#of cannot be empty");
                        for (directive.kind.of) |enum_token| {
                            const text = try self.enumText(enum_token);
                            if (@import("enumeration.zig").contains(enum_values.items, text))
                                return self.fail(.invalid_enum, enum_token.span, "duplicate decoded enum value");
                            try enum_values.append(self.allocator, text);
                        }
                    }
                }
                if (storage == .enumeration and enum_values.items.len == 0)
                    return self.fail(.invalid_enum, field.type.span, "enum requires a nonempty #of set");
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
                    if (storage == .enumeration and value.? == .text and
                        !@import("enumeration.zig").contains(enum_values.items, value.?.text))
                        return self.fail(.invalid_default, token.span, "enum default is not in its allowed set");
                }
                var uniques: std.ArrayList(resolved.UniqueConstraint) = .empty;
                for (field.directives) |directive| {
                    if (directive.kind != .native_unique) continue;
                    const unique = directive.kind.native_unique;
                    if (unique.fields.len != 0) return self.fail(.invalid_unique, directive.span, "Field uniqueness cannot specify field references");
                    var constraint_name: ?[]const u8 = null;
                    for (unique.options) |option| {
                        if (option.kind != .name) return self.fail(.invalid_unique, option.span, "Only #name is supported in unique options");
                        if (constraint_name != null) return self.fail(.duplicate_directive, option.span, "duplicate #name in unique options");
                        constraint_name = try self.name(field.name, option.kind.name);
                    }
                    if (uniques.items.len != 0) return self.fail(.duplicate_directive, directive.span, "duplicate field uniqueness declaration");
                    if (constraint_name) |n| for (columns[0..j]) |previous| {
                        for (previous.unique_constraints) |prior| {
                            if (prior.name) |p| if (std.ascii.eqlIgnoreCase(n, p))
                                return self.fail(.sql_name_collision, directive.span, "Named constraints collide within table (ASCII case-insensitive)");
                        }
                    };
                    try uniques.append(self.allocator, .{ .name = constraint_name });
                }
                columns[j] = .{
                    .dsl_name = try self.allocator.dupe(u8, field.name.text),
                    .sql_name = column_name,
                    .type = storage,
                    .enum_values = try enum_values.toOwnedSlice(self.allocator),
                    .nullable = field.type.nullable,
                    .primary_key = if (field_opts.reuse != null) .allow_reuse else if (field.primary_key) .standard else .none,
                    .default = value,
                    .documentation = try self.documentation(field.documentation),
                    .unique_constraints = try uniques.toOwnedSlice(self.allocator),
                };
            }
            tables[i] = .{ .dsl_name = try self.allocator.dupe(u8, table.name.text), .sql_name = sql_name, .columns = columns, .documentation = try self.documentation(table.documentation) };
            // Metadata (including final SQL names) must exist before resolving `_`.
            for (table.fields, 0..) |field, j| {
                var checks: std.ArrayList(resolved.Expression) = .empty;
                for (field.directives) |directive| {
                    if (directive.kind != .check) continue;
                    const result = try expression_resolver.resolveInto(self.allocator, directive.kind.check, .{ .table = tables[i], .field_index = j });
                    const expression = switch (result) {
                        .expression => |expression| expression,
                        .diagnostic => |d| return self.fail(.invalid_check, d.span, d.message),
                    };
                    if (expression_resolver.validateCheckResult(&expression)) |d|
                        return self.fail(.invalid_check, d.span, d.message);
                    try checks.append(self.allocator, expression);
                }
                columns[j].checks = try checks.toOwnedSlice(self.allocator);
            }
            var checks: std.ArrayList(resolved.Expression) = .empty;
            for (table.directives) |directive| {
                if (directive.kind != .check) continue;
                const result = try expression_resolver.resolveInto(self.allocator, directive.kind.check, .{ .table = tables[i], .field_index = null });
                const expression = switch (result) {
                    .expression => |expression| expression,
                    .diagnostic => |d| return self.fail(.invalid_check, d.span, d.message),
                };
                if (expression_resolver.validateCheckResult(&expression)) |d|
                    return self.fail(.invalid_check, d.span, d.message);
                try checks.append(self.allocator, expression);
            }
            tables[i].checks = try checks.toOwnedSlice(self.allocator);
        }
        return .{ .tables = tables };
    }

    fn documentation(self: *Context, docs: ?parsed.Documentation) Error!?resolved.Documentation {
        const value = docs orelse return null;
        return .{ .text = try self.allocator.dupe(u8, value.text), .span = value.span };
    }

    fn enumText(self: *Context, token: parsed.Token) Error![]const u8 {
        const text = token.text;
        if (text.len > 0 and (text[0] == '`' or text[0] == '#')) {
            const decoded = try self.backticks(token);
            if (!std.unicode.utf8ValidateSlice(decoded))
                return self.fail(.invalid_literal, token.span, "enum text must be valid UTF-8");
            return self.allocator.dupe(u8, decoded);
        }
        if (!@import("enumeration.zig").bare(text))
            return self.fail(.invalid_literal, token.span, "invalid bare enum word; use backticks for arbitrary text");
        return self.allocator.dupe(u8, text);
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
            .enum_text => storage == .enumeration,
            .raw_sql => storage != .enumeration,
        };
        if (!compatible) return self.fail(.invalid_default, token.span, "default does not match column type or nullability");
        return switch (value) {
            .enum_text => .{ .text = try self.enumText(token) },
            .boolean => .{ .boolean = try literals.boolean(self, token) },
            .integer => .{ .integer = try literals.integer(self, token) },
            .real => .{ .real = try literals.real(self, token) },
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
                try literals.nullValue(self, token);
                break :blk .null_value;
            },
            .raw_sql => .{ .raw_sql = try literals.rawSql(self, token) },
        };
    }

    fn string(self: *Context, token: parsed.Token) Error![]const u8 {
        return literals.string(self, token);
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
