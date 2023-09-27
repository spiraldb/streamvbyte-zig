const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("streamvbyte", .{
        .source_file = .{ .path = "src/streamvbyte.zig" },
    });

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/streamvbyte.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add streamvbyte dependency
    main_tests.linkLibC();
    main_tests.addIncludePath(.{ .path = "streamvbyte/include" });
    main_tests.addCSourceFiles(
        &.{
            "streamvbyte/src/streamvbyte_encode.c",
            "streamvbyte/src/streamvbyte_decode.c",
        },
        &.{ "-fPIC", "-std=c99", "-O3", "-Wall", "-Wextra", "-pedantic", "-Wshadow" },
    );

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
