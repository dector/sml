const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) void {
    const status = run(init);
    if (status != 0) std.process.exit(status);
}

fn report(stderr: *std.Io.Writer, operation: []const u8, failure: anyerror) void {
    stderr.print("sml: {s}: {s}\n", .{ operation, @errorName(failure) }) catch {};
}

fn run(init: std.process.Init) u8 {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = init.io;
    var err_file = std.Io.File.stderr().writer(io, &.{});
    const stderr = &err_file.interface;
    const args = init.minimal.args.toSlice(allocator) catch |failure| {
        report(stderr, "cannot read arguments", failure);
        return 1;
    };
    var out_file = std.Io.File.stdout().writer(io, &.{});
    const stdout = &out_file.interface;
    const input = switch (cli.arguments(args[1..])) {
        .invalid => {
            stderr.writeAll(cli.usage) catch {};
            return 2;
        },
        .help => {
            stdout.writeAll(cli.usage) catch |failure| {
                report(stderr, "cannot write stdout", failure);
                return 1;
            };
            return 0;
        },
        .input => |input| input,
    };
    const is_stdin = input == null or std.mem.eql(u8, input.?, "-");
    const name = if (is_stdin) "<stdin>" else input.?;
    const file = if (is_stdin) std.Io.File.stdin() else std.Io.Dir.cwd().openFile(io, name, .{}) catch |failure| {
        report(stderr, "cannot open input", failure);
        return 1;
    };
    defer if (!is_stdin) file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    const source = reader.interface.allocRemaining(allocator, .limited(cli.max_source_bytes)) catch |failure| {
        if (failure == error.StreamTooLong) {
            stderr.writeAll("sml: input exceeds 16 MiB source limit\n") catch {};
        } else {
            report(stderr, "cannot read input", reader.err orelse failure);
        }
        return 1;
    };
    const success = cli.compile(allocator, name, source, stdout, stderr) catch |failure| {
        report(stderr, "compilation or output failed", failure);
        return 1;
    };
    return if (success) 0 else 1;
}
