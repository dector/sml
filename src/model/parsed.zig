//! Parsed syntax, before semantic resolution. Names and type references are DSL
//! names; no SQL-name normalization, type lookup, or validation happens here.
//! Text slices borrow the source buffer, which must outlive this model. The caller
//! also owns the backing arrays (or uses OwnedSchema). Documentation text may
//! be arena-owned to join source lines. Spans are zero-based, end-exclusive.
const std = @import("std");

pub const Expression = @import("parsed_expression.zig").Expression;

pub const Span = struct {
    start: usize,
    end: usize,
};

/// An unmodified source token. Literal delimiters are included in `text`;
/// decoding and numeric conversion belong to semantic resolution.
pub const Token = struct {
    text: []const u8,
    span: Span,
};

pub const Schema = struct {
    tables: []const Table = &.{},
};

/// Attached declaration docs, with delimiters removed and lines joined by LF.
pub const Documentation = struct {
    text: []const u8,
    span: Span,
};

pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
};

/// Owns syntax arrays and joined docs, but token text still borrows source.
pub const OwnedSchema = struct {
    schema: Schema,
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

pub const Table = struct {
    name: Token,
    documentation: ?Documentation = null,
    fields: []const Field = &.{},
    directives: []const Directive = &.{},
    span: Span,
};

pub const Field = struct {
    name: Token,
    documentation: ?Documentation = null,
    type: TypeRef,
    /// Whether the declaration has a `!` marker. Reuse is a separate directive
    /// in syntax, unlike the combined policy in the resolved model.
    primary_key: bool = false,
    /// Stored `*field Target`: `type` names the target table, not a scalar type.
    /// Independent of primary-key membership; marker order is `*` then `!`.
    foreign_key: bool = false,
    default: ?Default = null,
    directives: []const Directive = &.{},
    span: Span,
};

/// A built-in/reusable type or stored-FK target table name; not looked up or lowered.
pub const TypeRef = struct {
    name: Token,
    nullable: bool = false,
    /// Includes the trailing `?`, when present.
    span: Span,
};

/// Defaults retain their original spelling, not resolved runtime values.
/// `text` includes ordinary or raw-string delimiters. `raw_sql` includes
/// backticks; enum backticks are instead contextual `enum_text`. Absence of a default is distinct from an explicit `null_value`.
/// There is no dedicated blob-literal syntax yet; raw SQL is its escape hatch.
pub const Default = union(enum) {
    integer: Token,
    boolean: Token,
    real: Token,
    text: Token,
    null_value: Token,
    raw_sql: Token,
    /// Bare word or backtick text in an enum default, never SQL.
    enum_text: Token,
    /// Contextual generator spelling, including the `::` prefix.
    generator: Token,
};

/// Preserve duplicates and source order for later scope/conflict diagnostics.
/// `of` members borrow source tokens, with bare words or backtick delimiters.
/// A `name` argument includes its backtick delimiters; it is not yet decoded.
/// The span covers the whole directive, including its argument.
pub const NativeUnique = struct {
    /// Empty for field scope; ordered DSL references for table scope.
    fields: []const Token = &.{},
    options: []const Directive = &.{},
};

pub const Index = struct {
    fields: []const Token = &.{},
    options: []const Directive = &.{},
};

pub const Directive = struct {
    kind: union(enum) {
        name: Token,
        /// Contextual action word; validated only during semantic resolution.
        on_delete: Token,
        native_unique: NativeUnique,
        index: Index,
        /// Argument-free flag, valid only inside index options.
        unique,
        allow_reuse,
        /// Field `? expr`, table `?? expr`, or either scope's `#check expr`.
        check: Expression,
        /// Row predicate, valid only inside index options.
        where: Expression,
        /// Contextual enum values; keep spelling and source order.
        of: []const Token,
    },
    span: Span,
};

test "parsed fields preserve unresolved names, nullability, and literal spelling" {
    const source = "price Money?(001.250)";
    const field: Field = .{
        .name = .{ .text = source[0..5], .span = .{ .start = 0, .end = 5 } },
        .type = .{
            .name = .{ .text = source[6..11], .span = .{ .start = 6, .end = 11 } },
            .nullable = true,
            .span = .{ .start = 6, .end = 12 },
        },
        .default = .{ .real = .{ .text = source[13..20], .span = .{ .start = 13, .end = 20 } } },
        .span = .{ .start = 0, .end = source.len },
    };
    try std.testing.expectEqualStrings("Money", field.type.name.text);
    try std.testing.expect(field.type.nullable);
    try std.testing.expectEqualStrings("Money?", source[field.type.span.start..field.type.span.end]);
    try std.testing.expectEqualStrings("001.250", field.default.?.real.text);
    try std.testing.expect(!field.primary_key);
}

test "parsed directives preserve duplicate options for later validation" {
    const source = "#allow reuse\n#allow reuse";
    const directives = [_]Directive{
        .{ .kind = .allow_reuse, .span = .{ .start = 0, .end = 12 } },
        .{ .kind = .allow_reuse, .span = .{ .start = 13, .end = source.len } },
    };
    try std.testing.expectEqual(@as(usize, 2), directives.len);
    for (directives) |directive| {
        try std.testing.expect(directive.kind == .allow_reuse);
        try std.testing.expectEqualStrings("#allow reuse", source[directive.span.start..directive.span.end]);
    }
}
