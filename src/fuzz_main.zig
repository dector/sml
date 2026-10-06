const std = @import("std");
const fuzz = @import("fuzz.zig");

const usage =
    \\Usage: zig build fuzz -- [options]
    \\  --seed N          Decimal u64 seed (default 5265996)
    \\  --iterations N    Number of cases (default 10000, positive)
    \\  --replay N        Run only zero-based case N (no prior cases)
    \\  --max-bytes N     Source bound, 1..8192 (default 8192)
    \\  --failure PATH    Exclusive failure artifact (default fuzz-failure.pzl)
    \\  --repro-dump PATH Write current input BEFORE each case; overwrites PATH
    \\  --help            Show this text (must be the only argument)
    \\Replay requires the same seed, index, max-bytes and harness revision.
    \\Not coverage-guided. SQL is emitted but not executed in SQLite.
    \\
;
const Options = struct {
    seed: u64 = 0x505a4c,
    iterations: u64 = 10000,
    replay: ?u64 = null,
    max_bytes: usize = fuzz.source_capacity,
    failure: []const u8 = "fuzz-failure.pzl",
    dump: ?[]const u8 = null,
    help: bool = false,
};
fn number(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidArguments;
    for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidArguments;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidArguments;
}
fn arguments(args: []const []const u8) !Options {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return .{ .help = true };
    var options: Options = .{};
    var seen: u8 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.InvalidArguments;
        const key = args[i];
        const value = args[i + 1];
        const keys = [_][]const u8{ "--seed", "--iterations", "--replay", "--max-bytes", "--failure", "--repro-dump" };
        var found = false;
        for (keys, 0..) |known, n| {
            if (!std.mem.eql(u8, key, known)) continue;
            const bit = @as(u8, 1) << @as(u3, @intCast(n));
            if (seen & bit != 0) return error.InvalidArguments;
            seen |= bit;
            found = true;
            switch (n) {
                0 => options.seed = try number(value),
                1 => {
                    options.iterations = try number(value);
                    if (options.iterations == 0) return error.InvalidArguments;
                },
                2 => options.replay = try number(value),
                3 => {
                    const bound = try number(value);
                    if (bound == 0 or bound > fuzz.source_capacity) return error.InvalidArguments;
                    options.max_bytes = @intCast(bound);
                },
                4 => {
                    if (value.len == 0) return error.InvalidArguments;
                    options.failure = value;
                },
                5 => {
                    if (value.len == 0) return error.InvalidArguments;
                    options.dump = value;
                },
                else => unreachable,
            }
        }
        if (!found) return error.InvalidArguments;
    }
    if (options.replay != null and seen & 2 != 0) return error.InvalidArguments;
    if (options.dump) |path| if (std.mem.eql(u8, path, options.failure)) return error.InvalidArguments;
    return options;
}

pub fn main(init: std.process.Init) void {
    const status = run(init) catch |err| blk: {
        std.debug.print("fuzz: infrastructure failure: {s}\n", .{@errorName(err)});
        break :blk @as(u8, 1);
    };
    if (status != 0) std.process.exit(status);
}
fn run(init: std.process.Init) !u8 {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const options = arguments(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    if (options.help) {
        var out = std.Io.File.stdout().writer(init.io, &.{});
        try out.interface.writeAll(usage);
        return 0;
    }
    const count: u64 = if (options.replay != null) 1 else options.iterations;
    var buffer: [fuzz.source_capacity]u8 = undefined;
    var offset: u64 = 0;
    while (offset < count) : (offset += 1) {
        const index = options.replay orelse offset;
        const source = fuzz.generate(options.seed, index, buffer[0..options.max_bytes]);
        if (options.dump) |path| {
            // Explicit opt-in overwrite. Exact bytes are available even after a panic.
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = source });
            std.debug.print("fuzz: current seed={d} index={d} max-bytes={d} dump={s}\n", .{ options.seed, index, options.max_bytes, path });
        }
        fuzz.runCase(source) catch |err| {
            std.debug.print("fuzz: failure {s}; replay: zig build fuzz -- --seed {d} --replay {d} --max-bytes {d}\n", .{ @errorName(err), options.seed, index, options.max_bytes });
            std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = options.failure, .data = source, .flags = .{ .exclusive = true } }) catch |write_error| {
                std.debug.print("fuzz: could not save {s}: {s}; exact input hex: {x}\n", .{ options.failure, @errorName(write_error), source });
                return 1;
            };
            std.debug.print("fuzz: saved exact input to {s}\n", .{options.failure});
            return 1;
        };
    }
    std.debug.print("fuzz: passed {d} cases; seed={d} max-bytes={d}", .{ count, options.seed, options.max_bytes });
    if (options.replay) |index| std.debug.print(" index={d}", .{index});
    std.debug.print("\n", .{});
    return 0;
}

test "fuzz argument validation" {
    try std.testing.expectEqual(@as(u64, 10000), (try arguments(&.{})).iterations);
    const options = try arguments(&.{ "--seed", "0", "--replay", "18446744073709551615", "--max-bytes", "1" });
    try std.testing.expectEqual(@as(u64, 0), options.seed);
    try std.testing.expectEqual(std.math.maxInt(u64), options.replay.?);
    try std.testing.expect((try arguments(&.{"--help"})).help);
    for ([_][]const []const u8{
        &.{"--wat"},                                 &.{ "--seed", "-1" },                       &.{ "--seed", "+1" },          &.{ "--seed", "0xff" },
        &.{ "--seed", "18446744073709551616" },      &.{ "--iterations", "0" },                  &.{ "--max-bytes", "8193" },   &.{ "--max-bytes", "0" },
        &.{ "--seed", "1", "--seed", "2" },          &.{ "--replay", "0", "--iterations", "1" }, &.{ "--help", "--seed", "1" }, &.{ "--failure", "" },
        &.{ "--failure", "a", "--repro-dump", "a" },
    }) |bad| try std.testing.expectError(error.InvalidArguments, arguments(bad));
}

test {
    _ = fuzz;
}
