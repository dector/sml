pub const parsed = @import("model/parsed.zig");
pub const resolved = @import("model/resolved.zig");
pub const emitter = @import("emitter.zig");

test {
    _ = parsed;
    _ = resolved;
    _ = emitter;
}
