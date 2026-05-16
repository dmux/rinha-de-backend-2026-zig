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

<<<<<<< Updated upstream
    // Use the specific Haswell target for the release build if requested
    const target_cpu = b.option([]const u8, "target_cpu", "Specific target CPU architecture (e.g. haswell)") orelse "";
    const resolved_target = if (std.mem.eql(u8, target_cpu, "haswell"))
        b.resolveTargetQuery(target_query)
=======
    // Use specific CPU targets if requested (e.g. for SIMD optimizations in Rinha)
    const target_cpu = b.option([]const u8, "target_cpu", "Specific target CPU architecture (e.g. haswell, x86_64_v2, x86_64_v3)") orelse "";
    const resolved_target = if (std.mem.eql(u8, target_cpu, "haswell"))
        b.resolveTargetQuery(target_query)
    else if (std.mem.eql(u8, target_cpu, "x86_64_v2"))
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 } })
    else if (std.mem.eql(u8, target_cpu, "x86_64_v3"))
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 } })
>>>>>>> Stashed changes
    else
        target;

    const domain_mod = b.createModule(.{
        .root_source_file = b.path("src/domain.zig"),
    });

    // Dependencies
    const httpz = b.dependency("httpz", .{
<<<<<<< Updated upstream
        .target = target,
=======
        .target = resolved_target,
>>>>>>> Stashed changes
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

    const preprocess_step = b.step("preprocess", "Build the preprocessor tool");
    preprocess_step.dependOn(&b.addInstallArtifact(preprocess, .{}).step);

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

    const httpz_mod = httpz.module("httpz");

    // Zig Proxy
    const proxy = b.addExecutable(.{
        .name = "zig-proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proxy.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    proxy.root_module.addImport("httpz", httpz_mod);
    b.installArtifact(proxy);

    const api_step = b.step("api", "Build the fraud-api and zig-proxy");
    api_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    api_step.dependOn(&b.addInstallArtifact(proxy, .{}).step);

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
