const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("sml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "sml",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(library);

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sml", .module = module }},
    });
    const executable = b.addExecutable(.{ .name = "pzl", .root_module = app_module });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the pzl compiler").dependOn(&run.step);

    const app_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sml", .module = module }},
    }) });
    const run_app_tests = b.addRunArtifact(app_tests);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run model and compiler tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_app_tests.step);
}
