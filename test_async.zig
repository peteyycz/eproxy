const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "async_http_test",
        .root_source_file = b.path("src/async_http_example.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add libxev dependency
    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("xev", libxev.module("xev"));

    b.installArtifact(exe);
}