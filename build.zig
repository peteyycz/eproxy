const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "io_uring_example",
        .target = target,
        .optimize = optimize,
    });

    // Add the C file
    exe.addCSourceFile(.{
        .file = b.path("io_uring_example.c"),
        .flags = &[_][]const u8{"-std=c11"},
    });

    // Link with C standard library
    exe.linkLibC();

    // Link with liburing
    exe.linkSystemLibrary("uring");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
