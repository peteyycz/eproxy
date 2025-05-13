const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "eproxy",
        .target = target,
        .optimize = optimize,
    });

    // Common C flags
    var c_flags = std.ArrayList([]const u8).init(b.allocator);
    defer c_flags.deinit();

    c_flags.append("-std=c11") catch unreachable;

    // Link with C standard library
    exe.linkLibC();

    // Conditionally link libraries based on target OS
    switch (target.result.os.tag) {
        .linux => {
            c_flags.append("-D_GNU_SOURCE") catch unreachable;
            c_flags.append("-DUSE_IO_URING=1") catch unreachable;
            // On Linux, link with liburing
            exe.linkSystemLibrary("uring");
        },
        .macos => {
            // On macOS no need to explicitly link kqueue
            // as it's part of the system libraries
            c_flags.append("-DUSE_KQUEUE=1") catch unreachable;
        },
        else => {},
    }

    // Add the C file
    exe.addCSourceFile(.{
        .file = b.path("main.c"),
        .flags = c_flags.items,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
