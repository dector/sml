pub const parsed = @import("model/parsed.zig");
pub const resolved = @import("model/resolved.zig");
pub const emitter = @import("emitter.zig");
pub const resolver = @import("resolver.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");
pub const expression_parser = @import("expression_parser.zig");
pub const expression_resolver = @import("expression_resolver.zig");
pub const expression_emitter = @import("expression_emitter.zig");

test {
    _ = parsed;
    _ = resolved;
    _ = @import("model/parsed_expression.zig");
    _ = @import("model/resolved_expression.zig");
    _ = emitter;
    _ = resolver;
    _ = tokenizer;
    _ = parser;
    _ = expression_parser;
    _ = expression_resolver;
    _ = expression_emitter;
    _ = @import("parser_integration_test.zig");
    _ = @import("foreign_key_syntax_test.zig");
    _ = @import("foreign_key_resolution_test.zig");
    _ = @import("boolean_test.zig");
    _ = @import("datetime_test.zig");
    _ = @import("enum_test.zig");
    _ = @import("check_test.zig");
    _ = @import("unique_test.zig");
    _ = @import("index_test.zig");
    _ = @import("partial_index_test.zig");
}
