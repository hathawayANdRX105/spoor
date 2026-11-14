const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-sqlite（vrischmann/zig-sqlite，zig-0.15.2 分支）：Zig 0.15.2 兼容的 SQLite Zig 绑定。
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    // SQLite C API 绑定模块（zig-sqlite 源码 sqlite.zig）。"sqlite" 绑定需在库模块和
    // 可执行文件根模块中都可见，否则库子模块在可执行文件的类型检查中解析不到该绑定。
    const sqlite_api = b.createModule(.{
        .root_source_file = sqlite_dep.path("sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_api.addIncludePath(sqlite_dep.path("."));
    sqlite_api.addIncludePath(sqlite_dep.path("c"));
    sqlite_api.addImport("build_options", b.addOptions().createModule());

    // SQLite amalgamation，由 spoor 自行编译并链接，以便控制编译宏（SQLITE_ENABLE_FTS5）。
    const amalgamation_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });

    // 库模块 "spoor"（self-import 供库内部文件用 @import("spoor") 引用根模块）。
    const mod = b.addModule("spoor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("spoor", mod);
    mod.addImport("sqlite", sqlite_api);
    // SQLite C 源码只编译一次（在 "spoor" 模块中），并随模块一起链接到每个 artifact。
    mod.addCSourceFile(.{
        .file = amalgamation_dep.path("sqlite3.c"),
        .flags = &.{"-std=c99", "-DSQLITE_ENABLE_FTS5"},
    });
    mod.addCSourceFile(.{
        .file = sqlite_dep.path("c/workaround.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addIncludePath(amalgamation_dep.path("."));
    mod.addIncludePath(sqlite_dep.path("c"));

    // CLI 可执行文件。
    const exe = b.addExecutable(.{
        .name = "spoor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spoor", .module = mod },
                .{ .name = "sqlite", .module = sqlite_api },
            },
        }),
    });

    // 这行声明 intent 让可执行文件在运行 `zig build` 时安装到安装前缀。
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // 库模块的测试。
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // 可执行文件根模块的测试。
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
