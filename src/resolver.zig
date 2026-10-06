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
    unsupported_feature,
    unknown_type,
    unknown_foreign_key_target,
    invalid_foreign_key_target,
    invalid_foreign_key_action,
    foreign_key_cycle,
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
    invalid_index,
    unknown_relationship_target,
    unknown_relationship_source,
    unknown_relationship_field,
    invalid_relationship_mapping,
    invalid_relationship_owner,
    unsupported_connection_relationship,
    invalid_connection,
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
            .on_delete => {
                if (table) return self.fail(.invalid_directive_scope, directive.span, "#onDelete requires a foreign-key field");
            },
            .check => {},
            .native_unique, .index => {},
            .unique => return self.fail(.invalid_directive_scope, directive.span, "#unique is index-option-only"),
            .where => return self.fail(.invalid_directive_scope, directive.span, "#where is index-option-only"),
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

    const TypeNode = struct {
        state: enum { pending, visiting, done } = .pending,
        concrete: ?parsed.Field = null,
        target_table: ?usize = null,
        target_column: ?usize = null,
    };

    // Phase one follows declared PK dependencies across the entire schema.
    // It intentionally does not apply local PK generation/default policy.
    fn inheritedType(self: *Context, input: parsed.Schema, graph: [][]TypeNode, ti: usize, ci: usize) Error!parsed.Field {
        const node = &graph[ti][ci];
        const field = input.tables[ti].fields[ci];
        if (node.state == .done) return node.concrete.?;
        if (node.state == .visiting)
            return self.fail(.foreign_key_cycle, field.type.name.span, "Foreign-key type dependency cycle has no concrete underlying storage type");
        node.state = .visiting;
        if (field.primary_key and field.type.nullable)
            return self.fail(.nullable_primary_key, field.type.span, "primary-key fields cannot be nullable");
        const concrete = if (field.foreign_key) blk: {
            const target = for (input.tables, 0..) |table, i| {
                if (std.mem.eql(u8, table.name.text, field.type.name.text)) break i;
            } else return self.fail(.unknown_foreign_key_target, field.type.name.span, "Unknown DSL table in foreign-key target");
            var key: ?usize = null;
            for (input.tables[target].fields, 0..) |candidate, i| {
                if (!candidate.primary_key) continue;
                if (key != null) return self.fail(.invalid_foreign_key_target, field.type.name.span, "Foreign-key target must have exactly one declared primary-key field (composite key is unsupported)");
                key = i;
            }
            const ki = key orelse return self.fail(.invalid_foreign_key_target, field.type.name.span, "Foreign-key target must have exactly one declared primary-key field (no primary key declared)");
            const pk = input.tables[target].fields[ki];
            if (pk.type.nullable) return self.fail(.nullable_primary_key, pk.type.span, "primary-key fields cannot be nullable");
            node.target_table = target;
            node.target_column = ki;
            break :blk try self.inheritedType(input, graph, target, ki);
        } else field;
        if (field.primary_key and std.mem.eql(u8, concrete.type.name.text, "bool"))
            return self.fail(.invalid_primary_key, field.type.name.span, "Boolean fields cannot be primary keys (including composite keys)");
        node.concrete = concrete;
        node.state = .done;
        return concrete;
    }

    fn schema(self: *Context, source: parsed.Schema) Error!resolved.Schema {
        const input = try @import("connection_expansion.zig").expand(self, source);
        const graph = try self.allocator.alloc([]TypeNode, input.tables.len);
        // Validate DSL table identity before resolving references.
        for (input.tables, 0..) |table, i| {
            for (input.tables[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name.text, table.name.text))
                    return self.fail(.duplicate_dsl_name, table.name.span, "duplicate DSL table name");
            }
            graph[i] = try self.allocator.alloc(TypeNode, table.fields.len);
            @memset(graph[i], .{});
        }
        for (input.tables, 0..) |table, i| for (table.fields, 0..) |_, j| {
            _ = try self.inheritedType(input, graph, i, j);
        };
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
                const concrete = graph[i][j].concrete.?;
                if (field.foreign_key) {
                    for (field.directives) |directive| {
                        if (directive.kind == .allow_reuse)
                            return self.fail(.invalid_id_reuse, directive.span, "#allow reuse is invalid on foreign-key fields");
                        if (directive.kind == .of)
                            return self.fail(.invalid_directive_scope, directive.span, "Foreign-key enum values are inherited; #of is not allowed");
                    }
                }
                for (table.fields[0..j]) |previous| {
                    if (std.mem.eql(u8, previous.name.text, field.name.text))
                        return self.fail(.duplicate_dsl_name, field.name.span, "duplicate DSL field name");
                }
                const field_opts = try self.options(field.directives, false);
                var delete_action: resolved.DeleteAction = .restrict;
                var has_delete_action = false;
                for (field.directives) |directive| {
                    if (directive.kind != .on_delete) continue;
                    if (!field.foreign_key) return self.fail(.invalid_directive_scope, directive.span, "#onDelete requires a foreign-key field");
                    if (has_delete_action) return self.fail(.duplicate_directive, directive.span, "duplicate #onDelete directive");
                    has_delete_action = true;
                    const action = directive.kind.on_delete;
                    delete_action = if (std.mem.eql(u8, action.text, "restrict")) .restrict else if (std.mem.eql(u8, action.text, "cascade")) .cascade else if (std.mem.eql(u8, action.text, "setNull")) .set_null else return self.fail(.invalid_foreign_key_action, action.span, "Unknown #onDelete action; expected restrict, cascade or setNull");
                    if (delete_action == .set_null and !field.type.nullable)
                        return self.fail(.invalid_foreign_key_action, directive.span, "#onDelete setNull requires a nullable foreign-key field");
                }
                const column_name = try self.name(field.name, field_opts.name);
                for (columns[0..j]) |previous| {
                    if (std.ascii.eqlIgnoreCase(previous.sql_name, column_name))
                        return self.fail(.sql_name_collision, if (field_opts.name) |n| n.span else field.name.span, "SQL column names collide (ASCII case-insensitive)");
                }
                const storage: resolved.StorageType = if (std.mem.eql(u8, concrete.type.name.text, "int")) .integer else if (std.mem.eql(u8, concrete.type.name.text, "real")) .real else if (std.mem.eql(u8, concrete.type.name.text, "str")) .text else if (std.mem.eql(u8, concrete.type.name.text, "blob")) .blob else if (std.mem.eql(u8, concrete.type.name.text, "bool")) .boolean else if (std.mem.eql(u8, concrete.type.name.text, "datetime")) .datetime else if (std.mem.eql(u8, concrete.type.name.text, "enum")) .enumeration else return self.fail(.unknown_type, concrete.type.name.span, "unknown type; supported builtins are int, real, str, blob, bool, datetime, enum");
                var enum_values: std.ArrayList([]const u8) = .empty;
                for (concrete.directives) |directive| {
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
                    return self.fail(.invalid_enum, concrete.type.span, "enum requires a nonempty #of set");
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
                    if (field.primary_key and !field.foreign_key and storage == .integer and key_count == 1)
                        return self.fail(.default_on_auto_primary_key, token.span, "auto-generated integer primary keys cannot have defaults");
                    // A backtick FK default is enum text only after target lookup.
                    const typed_default: parsed.Default = if (field.foreign_key and storage == .enumeration and default == .raw_sql)
                        .{ .enum_text = default.raw_sql }
                    else
                        default;
                    value = try self.defaultValue(typed_default, storage, field.type.nullable);
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
                    .foreign_key = if (graph[i][j].target_table) |target| .{
                        .delete_action = delete_action,
                        .target_table_sql_name = try self.name(input.tables[target].name, (try self.options(input.tables[target].directives, true)).name),
                        .target_column_sql_name = try self.name(input.tables[target].fields[graph[i][j].target_column.?].name, (try self.options(input.tables[target].fields[graph[i][j].target_column.?].directives, false)).name),
                    } else null,
                    .documentation = try self.documentation(field.documentation),
                    .unique_constraints = try uniques.toOwnedSlice(self.allocator),
                };
            }
            tables[i] = .{ .dsl_name = try self.allocator.dupe(u8, table.name.text), .sql_name = sql_name, .columns = columns, .documentation = try self.documentation(table.documentation) };
            var table_uniques: std.ArrayList(resolved.UniqueConstraint) = .empty;
            for (table.directives) |directive| {
                if (directive.kind != .native_unique) continue;
                const unique = directive.kind.native_unique;
                if (unique.fields.len == 0) return self.fail(.invalid_unique, directive.span, "Table uniqueness requires a nonempty field list");
                const indices = try self.allocator.alloc(usize, unique.fields.len);
                for (unique.fields, 0..) |reference, n| {
                    const index = for (columns, 0..) |column, k| {
                        if (std.mem.eql(u8, reference.text, column.dsl_name)) break k;
                    } else return self.fail(.invalid_unique, reference.span, "Unknown field in unique constraint");
                    for (indices[0..n]) |prior| if (prior == index)
                        return self.fail(.invalid_unique, reference.span, "Repeated field in unique constraint");
                    indices[n] = index;
                }
                var constraint_name: ?[]const u8 = null;
                for (unique.options) |option| {
                    if (option.kind != .name) return self.fail(.invalid_unique, option.span, "Only #name is supported in unique options");
                    if (constraint_name != null) return self.fail(.duplicate_directive, option.span, "duplicate #name in unique options");
                    constraint_name = try self.name(table.name, option.kind.name);
                }
                for (columns, 0..) |column, k| for (column.unique_constraints) |prior| {
                    if (indices.len == 1 and indices[0] == k)
                        return self.fail(.duplicate_directive, directive.span, "Duplicate uniqueness on the same fields");
                    if (constraint_name) |n| if (prior.name) |p| if (std.ascii.eqlIgnoreCase(n, p))
                        return self.fail(.sql_name_collision, directive.span, "Named constraints collide within table (ASCII case-insensitive)");
                };
                for (table_uniques.items) |prior| {
                    if (@import("unique.zig").sameFields(indices, prior.columns))
                        return self.fail(.duplicate_directive, directive.span, "Duplicate uniqueness on the same fields");
                    if (constraint_name) |n| if (prior.name) |p| if (std.ascii.eqlIgnoreCase(n, p))
                        return self.fail(.sql_name_collision, directive.span, "Named constraints collide within table (ASCII case-insensitive)");
                }
                try table_uniques.append(self.allocator, .{ .name = constraint_name, .columns = indices });
            }
            tables[i].unique_constraints = try table_uniques.toOwnedSlice(self.allocator);
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
        // Resolve indexes only after all table/column names are final, including
        // later declarations. Constraint names are deliberately not global.
        for (input.tables, 0..) |table, i| {
            var indexes: std.ArrayList(resolved.Index) = .empty;
            for (table.fields, 0..) |field, j| for (field.directives) |directive| {
                if (directive.kind == .index) try indexes.append(self.allocator, try self.resolveIndex(directive, tables[i], j));
            };
            for (table.directives) |directive| {
                if (directive.kind == .index) try indexes.append(self.allocator, try self.resolveIndex(directive, tables[i], null));
            }
            tables[i].indexes = try indexes.toOwnedSlice(self.allocator);
            for (tables[i].indexes, 0..) |index, n| {
                for (tables) |other| if (std.ascii.eqlIgnoreCase(index.sql_name, other.sql_name))
                    return self.fail(.sql_name_collision, table.span, "SQL index and table names collide (ASCII case-insensitive)");
                for (tables[0..i]) |other| for (other.indexes) |prior| {
                    if (std.ascii.eqlIgnoreCase(index.sql_name, prior.sql_name)) return self.fail(.sql_name_collision, table.span, "SQL index names collide; specify distinct #name options");
                };
                for (tables[i].indexes[0..n]) |prior| {
                    if (std.ascii.eqlIgnoreCase(index.sql_name, prior.sql_name)) return self.fail(.sql_name_collision, table.span, "SQL index names collide; specify distinct #name options");
                }
            }
        }
        // Explicit names across the entire schema take precedence over generated
        // FK indexes. Never silently suffix a collision or use a partial index.
        for (tables, 0..) |*table, ti| {
            var indexes: std.ArrayList(resolved.Index) = .empty;
            try indexes.appendSlice(self.allocator, table.indexes);
            for (table.columns, 0..) |column, ci| {
                if (column.foreign_key == null or fkCovered(table.*, ci)) continue;
                const span = input.tables[ti].fields[ci].span;
                const columns = try self.allocator.dupe(usize, &.{ci});
                const sql_name = try self.indexName(table.*, columns);
                if (std.ascii.startsWithIgnoreCase(sql_name, "sqlite_"))
                    return self.fail(.invalid_identifier, span, "Index names beginning sqlite_ are reserved");
                for (tables) |other| {
                    if (std.ascii.eqlIgnoreCase(sql_name, other.sql_name))
                        return self.fail(.sql_name_collision, span, "Automatic FK index name collides with a table; rename the table or FK column (no automatic suffix)");
                    for (other.indexes) |prior| {
                        if (std.ascii.eqlIgnoreCase(sql_name, prior.sql_name))
                            return self.fail(.sql_name_collision, span, "Automatic FK index name collides with an index; rename the explicit index or FK column (no automatic suffix)");
                    }
                }
                for (indexes.items) |prior| {
                    if (std.ascii.eqlIgnoreCase(sql_name, prior.sql_name))
                        return self.fail(.sql_name_collision, span, "Automatic FK index names collide; rename the FK column (no automatic suffix)");
                }
                try indexes.append(self.allocator, .{ .columns = columns, .sql_name = sql_name });
            }
            table.indexes = try indexes.toOwnedSlice(self.allocator);
        }
        // Preserve header order and own roles. Generated keys have known slots;
        // explicit repeated-table roles remain unbound (no naming inference).
        for (input.tables, 0..) |table, ti| {
            const connection = table.connection orelse continue;
            const endpoints = try self.allocator.alloc(resolved.Endpoint, connection.endpoints.len);
            for (connection.endpoints, 0..) |endpoint, ei| {
                const target = for (input.tables, 0..) |candidate, index| {
                    if (std.mem.eql(u8, candidate.name.text, endpoint.table.text)) break index;
                } else return self.fail(.invalid_connection, endpoint.table.span, "Unknown connection endpoint table");
                if (input.tables[target].connection != null)
                    return self.fail(.unsupported_feature, endpoint.table.span, "Nested connection endpoints are unsupported");
                endpoints[ei] = .{ .table_index = target, .role = if (endpoint.role) |role| try self.allocator.dupe(u8, role.text) else null };
                var count: usize = 0;
                for (connection.endpoints) |other| {
                    if (std.mem.eql(u8, other.table.text, endpoint.table.text)) count += 1;
                }
                if (connection.generated_keys_span != null) endpoints[ei].column_index = ei;
                if (count == 1) for (tables[ti].columns, 0..) |column, ci| {
                    if (column.primary_key != .none and @import("connection_validation.zig").matches(column, tables[target])) endpoints[ei].column_index = ci;
                };
            }
            tables[ti].connection = .{ .endpoints = endpoints };
        }
        for (input.tables, 0..) |table, ti| {
            if (table.connection) |connection| {
                @import("connection_validation.zig").validate(.{ .tables = tables }, tables[ti]) catch
                    return self.fail(.invalid_connection, connection.span, "Connection requires nonnullable primary-key foreign keys matching its normal endpoints and unique roles for repeated tables");
            }
        }
        return .{ .tables = tables, .relationships = try self.relationships(input, tables) };
    }

    // Direct backrefs use DSL identity for lookup and final SQL identity for FK
    // validation. Virtual names never enter the SQL identifier namespace.
    fn relationships(self: *Context, input: parsed.Schema, tables: []const resolved.Table) Error![]const resolved.Relationship {
        var output: std.ArrayList(resolved.Relationship) = .empty;
        for (input.tables, 0..) |table, owner| {
            for (table.relationships, 0..) |relationship, ri| {
                for (table.fields) |field| {
                    if (std.mem.eql(u8, field.name.text, relationship.name.text))
                        return self.fail(.duplicate_dsl_name, relationship.name.span, "Relationship name collides with a stored field");
                }
                for (table.relationships[0..ri]) |prior| {
                    if (std.mem.eql(u8, prior.name.text, relationship.name.text))
                        return self.fail(.duplicate_dsl_name, relationship.name.span, "duplicate DSL relationship name");
                }
                if (!@import("unique.zig").dslName(relationship.name.text))
                    return self.fail(.invalid_identifier, relationship.name.span, "Invalid DSL relationship name");
                if (relationship.collection and relationship.target.nullable)
                    return self.fail(.invalid_relationship_mapping, relationship.target.span, "Relationship collections cannot be nullable");
                if (!relationship.collection and !relationship.target.nullable)
                    return self.fail(.invalid_relationship_mapping, relationship.target.span, "Singular relationships must be nullable");
                const target = for (tables, 0..) |candidate, ti| {
                    if (std.mem.eql(u8, candidate.dsl_name, relationship.target.name.text)) break ti;
                } else return self.fail(.unknown_relationship_target, relationship.target.name.span, "Unknown DSL table in relationship target");
                const source = for (tables, 0..) |candidate, ti| {
                    if (std.mem.eql(u8, candidate.dsl_name, relationship.source_table.text)) break ti;
                } else return self.fail(.unknown_relationship_source, relationship.source_table.span, "Unknown DSL table in relationship source");
                if (tables[source].connection == null and source != target)
                    return self.fail(.unsupported_connection_relationship, relationship.source_table.span, "Different source and target tables require a declared connection");
                if (tables[source].connection == null and relationship.destination_field != null)
                    return self.fail(.invalid_relationship_mapping, relationship.destination_field.?.span, "Direct backrefs cannot have a destination hint");
                const backing = for (tables[source].columns, 0..) |column, ci| {
                    if (std.mem.eql(u8, column.dsl_name, relationship.source_field.text)) break ci;
                } else return self.fail(.unknown_relationship_field, relationship.source_field.span, "Unknown stored DSL field in relationship source");
                if (tables[source].columns[backing].foreign_key == null)
                    return self.fail(.invalid_relationship_mapping, relationship.source_field.span, "Relationship source must be a stored foreign-key field");
                var pk: ?usize = null;
                for (tables[owner].columns, 0..) |column, ci| {
                    if (column.primary_key == .none) continue;
                    if (pk != null)
                        return self.fail(.invalid_relationship_owner, relationship.span, "Relationship owner must have exactly one primary-key field");
                    pk = ci;
                }
                if (pk == null) return self.fail(.invalid_relationship_owner, relationship.span, "Relationship owner must have exactly one primary-key field");
                const validation = @import("relationship_validation.zig");
                if (!validation.references(tables[source].columns[backing], tables[owner]))
                    return self.fail(.invalid_relationship_mapping, relationship.source_field.span, "Relationship source foreign key must reference the owner's single primary key");
                if (!relationship.collection and !@import("unique.zig").singleColumn(tables[source], backing))
                    return self.fail(.invalid_relationship_mapping, relationship.source_field.span, "Singular relationship backing FK must be unique as a single column (not composite or partial)");
                const mapping_schema: resolved.Schema = .{ .tables = tables };
                var destination: ?usize = null;
                if (tables[source].connection != null) {
                    if (!validation.endpoint(mapping_schema, tables[source], backing, owner))
                        return self.fail(.invalid_relationship_mapping, relationship.source_field.span, "Connection source must be an endpoint primary-key foreign key referencing the owner");
                    if (relationship.destination_field) |hint| {
                        destination = for (tables[source].columns, 0..) |column, ci| {
                            if (std.mem.eql(u8, column.dsl_name, hint.text)) break ci;
                        } else return self.fail(.unknown_relationship_field, hint.span, "Unknown stored DSL destination field");
                        if (destination.? == backing or !validation.endpoint(mapping_schema, tables[source], destination.?, target))
                            return self.fail(.invalid_relationship_mapping, hint.span, "Destination must be a different endpoint primary-key foreign key referencing the declared target");
                    } else {
                        for (tables[source].columns, 0..) |_, ci| {
                            if (ci == backing or !validation.endpoint(mapping_schema, tables[source], ci, target)) continue;
                            if (destination != null)
                                return self.fail(.invalid_relationship_mapping, relationship.source_field.span, "Ambiguous connection destination; select a DSL field with <<field");
                            destination = ci;
                        }
                        if (destination == null)
                            return self.fail(.invalid_relationship_mapping, relationship.target.span, "Connection has no other endpoint key referencing the declared target");
                    }
                }
                const mapping: resolved.Relationship = .{
                    .dsl_name = relationship.name.text,
                    .owner_table_index = owner,
                    .target_table_index = target,
                    .source_table_index = source,
                    .backing_column_index = backing,
                    .destination_column_index = destination,
                    .cardinality = if (relationship.collection) .many else .optional_one,
                };
                validation.validate(mapping_schema, mapping) catch
                    return self.fail(.invalid_relationship_mapping, relationship.span, "Invalid relationship mapping");
                try output.append(self.allocator, .{
                    .dsl_name = try self.allocator.dupe(u8, relationship.name.text),
                    .owner_table_index = owner,
                    .target_table_index = target,
                    .source_table_index = source,
                    .backing_column_index = backing,
                    .destination_column_index = destination,
                    .cardinality = if (relationship.collection) .many else .optional_one,
                    .documentation = try self.documentation(relationship.documentation),
                    .span = relationship.span,
                });
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn fkCovered(table: resolved.Table, ci: usize) bool {
        // The first PK column covers an equality lookup, including rowid PKs.
        for (table.columns, 0..) |column, i| {
            if (column.primary_key != .none) {
                if (i == ci) return true;
                break;
            }
        }
        if (table.columns[ci].unique_constraints.len != 0) return true;
        for (table.unique_constraints) |constraint| {
            if (constraint.columns.len != 0 and constraint.columns[0] == ci) return true;
        }
        for (table.indexes) |index| {
            if (index.predicate == null and index.columns.len != 0 and index.columns[0] == ci) return true;
        }
        return false;
    }

    fn indexName(self: *Context, table: resolved.Table, columns: []const usize) Error![]const u8 {
        var generated: std.ArrayList(u8) = .empty;
        try generated.appendSlice(self.allocator, table.sql_name);
        for (columns) |j| {
            try generated.append(self.allocator, '_');
            try generated.appendSlice(self.allocator, table.columns[j].sql_name);
        }
        try generated.appendSlice(self.allocator, "_idx");
        return generated.toOwnedSlice(self.allocator);
    }

    fn resolveIndex(self: *Context, directive: parsed.Directive, table: resolved.Table, field: ?usize) Error!resolved.Index {
        const payload = directive.kind.index;
        if (field != null and payload.fields.len != 0) return self.fail(.invalid_index, directive.span, "Field index cannot specify references");
        if (field == null and payload.fields.len == 0) return self.fail(.invalid_index, directive.span, "Table index requires at least one field");
        const columns = try self.allocator.alloc(usize, if (field != null) 1 else payload.fields.len);
        if (field) |j| {
            columns[0] = j;
        } else for (payload.fields, 0..) |reference, n| {
            const j = for (table.columns, 0..) |column, k| {
                if (std.mem.eql(u8, column.dsl_name, reference.text)) break k;
            } else return self.fail(.invalid_index, reference.span, "Unknown field in index");
            for (columns[0..n]) |prior| if (prior == j) return self.fail(.invalid_index, reference.span, "Repeated field in index");
            columns[n] = j;
        }
        var override: ?parsed.Token = null;
        var unique = false;
        var predicate: ?resolved.Expression = null;
        for (payload.options) |option| switch (option.kind) {
            .name => |exact| {
                if (override != null) return self.fail(.duplicate_directive, option.span, "duplicate #name in index options");
                override = exact;
            },
            .unique => {
                if (unique) return self.fail(.duplicate_directive, option.span, "duplicate #unique in index options");
                unique = true;
            },
            .where => |input| {
                if (predicate != null) return self.fail(.duplicate_directive, option.span, "duplicate #where in index options");
                const result = try expression_resolver.resolveInto(self.allocator, input, .{ .table = table });
                predicate = switch (result) {
                    .expression => |expression| expression,
                    .diagnostic => |d| return self.fail(.invalid_index, d.span, d.message),
                };
                if (expression_resolver.validateCheckResult(&predicate.?)) |d|
                    return self.fail(.invalid_index, d.span, "Index predicate must be Boolean or trusted raw SQL");
            },
            else => return self.fail(.invalid_index, option.span, "Only #name, #unique and #where are supported in index options"),
        };
        const sql_name = if (override) |exact| try self.name(.{ .text = "", .span = directive.span }, exact) else try self.indexName(table, columns);
        if (std.ascii.startsWithIgnoreCase(sql_name, "sqlite_")) return self.fail(.invalid_identifier, if (override) |o| o.span else directive.span, "Index names beginning sqlite_ are reserved");
        return .{ .columns = columns, .sql_name = sql_name, .unique = unique, .predicate = predicate };
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
