const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // core: libzarcutil
    const core = b.addStaticLibrary(.{
        .name = "zarcutil",
        .root_source_file = b.path("core/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.linkLibC();
    core.addIncludePath(b.path("include"));
    b.installArtifact(core);

    // cli: zarc
    const cli = b.addExecutable(.{
        .name = "zarc",
        .root_source_file = b.path("cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli.linkLibrary(core);
    cli.linkLibC();
    cli.addIncludePath(b.path("include"));
    b.installArtifact(cli);

    // run
    const run_cmd = b.addRunArtifact(cli);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the zarc CLI");
    run_step.dependOn(&run_cmd.step);

    // test: core + cli
    const core_tests = b.addTest(.{
        .root_source_file = b.path("core/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_tests.linkLibC();
    core_tests.addIncludePath(b.path("include"));

    const cli_tests = b.addTest(.{
        .root_source_file = b.path("cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tests.linkLibrary(core);
    cli_tests.linkLibC();

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
