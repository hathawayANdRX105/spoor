const std = @import("std");

pub fn build(b: *std.Build) void {
    // 默认 musl：CachyOS 的 GCC 16 crt1.o 含 .sframe（R_X86_64_PC64 relocation），
    // zig 0.15.2 的 linker 不认识；musl 用 zig 自带 crt，绕开该问题。
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});

    // vrischmann/zig-sqlite：module("sqlite") 已内置 SQLite 编译、sqlite3.h include path 与 link_libc。
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });

    // 库模块 "spoor"（self-import 供库内部文件用 @import("spoor") 引用根模块）。
    const mod = b.addModule("spoor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("spoor", mod);
    mod.addImport("sqlite", sqlite_dep.module("sqlite"));

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
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
