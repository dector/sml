//! Internal CLI logic. SQL is staged in memory before touching the output writer.
const std = @import("std");
const compiler = @import("sml");

pub const max_source_bytes = 16 * 1024 * 1024;
pub const usage = "Usage: sml [FILE|-]\n       sml --help\nReads stdin by default. Use -- before a filename beginning with -.\n";
pub const Arguments = union(enum) { input: ?[]const u8, help, invalid };

/// Validate the entire argument list before reading input or displaying help.
pub fn arguments(args: []const []const u8) Arguments {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) return .help;
    var positional: ?[]const u8 = null;
    var literal = false;
    for (args) |arg| {
        if (!literal and std.mem.eql(u8, arg, "--")) {
            literal = true;
            continue;
        }
        if (!literal and arg.len > 1 and arg[0] == '-') return .invalid;
        if (positional != null) return .invalid;
        positional = arg;
    }
    return .{ .input = positional };
}

/// Returns false for a source diagnostic. Allocation and writer errors propagate.
/// No bytes reach stdout until parsing, resolution and emission all succeed.
pub fn compile(allocator: std.mem.Allocator, name: []const u8, source: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var syntax = try compiler.parser.parse(allocator, source);
    if (syntax == .diagnostic) {
        try compiler.diagnostics.formatParser(stderr, name, source, syntax.diagnostic);
        return false;
    }
    defer syntax.schema.deinit();
    var semantic = try compiler.resolver.resolve(allocator, syntax.schema.schema);
    if (semantic == .diagnostic) {
        try compiler.diagnostics.formatResolver(stderr, name, source, semantic.diagnostic);
        return false;
    }
    defer semantic.schema.deinit();
    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();
    compiler.emitter.emit(semantic.schema.schema, &sql.writer) catch |failure| {
        // Allocating writers map allocation failure to WriteFailed.
        if (failure == error.WriteFailed) return error.OutOfMemory;
        return failure;
    };
    try stdout.writeAll(sql.written());
    return true;
}

test "argument validation" {
    try std.testing.expect(arguments(&.{}) == .input);
    try std.testing.expect(arguments(&.{"-"}) == .input);
    try std.testing.expect(arguments(&.{"--help"}) == .help);
    try std.testing.expect(arguments(&.{"-h"}) == .help);
    try std.testing.expectEqualStrings("-input", arguments(&.{ "--", "-input" }).input.?);
    for ([_][]const []const u8{ &.{"--unknown"}, &.{ "a", "b" }, &.{ "--help", "a" }, &.{ "a", "-h" }, &.{ "--", "a", "b" } }) |args| {
        try std.testing.expect(arguments(args) == .invalid);
    }
}

test "pipeline stages SQL and formats diagnostics" {
    for ([_][]const u8{ "Item {\n  value\n}\n", "Item {\n  value Unknown\n}\n" }) |source| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer err.deinit();
        try std.testing.expect(!try compile(std.testing.allocator, "<stdin>", source, &out.writer, &err.writer));
        try std.testing.expectEqualStrings("", out.written());
        try std.testing.expect(std.mem.indexOf(u8, err.written(), "error [") != null);
    }
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();
    const ok = compile(allocator, "fixture", @embedFile("testdata/parser/named_checks.sml"), &out.writer, &err.writer) catch |failure| {
        try std.testing.expectEqualStrings("", out.written());
        return if (failure == error.WriteFailed) error.OutOfMemory else failure;
    };
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings(@embedFile("testdata/parser/named_checks.expect.sql"), out.written());
    try std.testing.expectEqualStrings("", err.written());
}

test "stdout writer failure propagates without source diagnostics" {
    var stdout: std.Io.Writer = .fixed(&.{});
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectError(error.WriteFailed, compile(std.testing.allocator, "<stdin>", "", &stdout, &stderr.writer));
    try std.testing.expectEqualStrings("", stderr.written());
}

test "pipeline allocation failures clean up without output" {
    // Arena growth can resize in place depending on the backing allocator's
    // address layout. Force relocation so every failing allocation run agrees.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationExercise, .{});
}
