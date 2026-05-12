const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CPU features for Haswell (AVX2, FMA, etc.) as required by the plan
    const haswell_features = std.Target.x86.featureSet(&.{
        .avx2,
        .fma,
        .f16c,
        .bmi,
        .bmi2,
        .popcnt,
        .lzcnt,
    });

    const target_query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .cpu_features_add = haswell_features,
    };

    // Use the specific Haswell target for the release build if requested
    const target_cpu = b.option([]const u8, "target_cpu", "Specific target CPU architecture (e.g. haswell)") orelse "";
    const resolved_target = if (std.mem.eql(u8, target_cpu, "haswell"))
        b.resolveTargetQuery(target_query)
    else
        target;

    const domain_mod = b.createModule(.{
        .root_source_file = b.path("src/domain.zig"),
    });

    // Dependencies
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // Main API Executable
    const exe = b.addExecutable(.{
        .name = "fraud-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addImport("domain", domain_mod);
    b.installArtifact(exe);

    // Preprocess Tool
    const preprocess = b.addExecutable(.{
        .name = "preprocess",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/preprocess.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    preprocess.root_module.addImport("domain", domain_mod);
    b.installArtifact(preprocess);

    // Validate Tool
    const validate = b.addExecutable(.{
        .name = "validate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/validate.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    validate.root_module.addImport("domain", domain_mod);
    b.installArtifact(validate);

    // Run Command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit Tests
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.addImport("domain", domain_mod);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Linter (zig fmt check)
    const fmt_step = b.step("lint", "Check formatting");
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "tools", "build.zig", "build.zig.zon" },
        .check = true,
    });
    fmt_step.dependOn(&fmt_check.step);
}
