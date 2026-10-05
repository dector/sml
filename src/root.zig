pub const parsed = @import("model/parsed.zig");
pub const resolved = @import("model/resolved.zig");
pub const emitter = @import("emitter.zig");
pub const resolver = @import("resolver.zig");

test {
    _ = parsed;
    _ = resolved;
    _ = emitter;
    _ = resolver;
}
