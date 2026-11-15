const std = @import("std");

pub fn build(b: *std.Build) void {
    // 默认 musl：0.15.2 时代绕开 CachyOS GCC16 crt1.o 的 linker 问题；
    // 0.17.1 已修复 linker，但 musl 静态行为保留（部署简单）。
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});

    // 库模块 "spoor"（self-import 供库内部文件用 @import("spoor") 引用根模块）。
    const mod = b.addModule("spoor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("spoor", mod);

    // SQLite amalgamation（自带 vendor，编译宏可控，含 FTS5）。
    mod.addIncludePath(b.path("vendor"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_DQS=0" },
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/workaround.c"),
        .flags = &.{"-std=c99"},
    });
    mod.link_libc = true;

    // CLI 可执行文件。
    const exe = b.addExecutable(.{
        .name = "spoor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spoor", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
