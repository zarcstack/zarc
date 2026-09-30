const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zarcutil_module = b.createModule(.{
        .root_source_file = b.path("core/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core = b.addLibrary(.{
        .name = "zarcutil",
        .root_module = zarcutil_module,
        .linkage = .static,
    });
    b.installArtifact(core);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("zarcutil", zarcutil_module);
    cli_module.addIncludePath(b.path("include"));

    const cli = b.addExecutable(.{
        .name = "zarc",
        .root_module = cli_module,
    });
    b.installArtifact(cli);

    const run_cmd = b.addRunArtifact(cli);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the zarc CLI");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .root_module = zarcutil_module,
    });
    const cli_tests = b.addTest(.{
        .root_module = cli_module,
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
