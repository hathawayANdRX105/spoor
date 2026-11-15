//! SQLite 连接 / 事务 / 迁移封装。所有存储都走这一层。
//! 底层绑定是本项目自带的 sqlite3.zig（原 zig-sqlite 在 0.17 的 @cImport 被移除后替换）。

const std = @import("std");
const binding = @import("sqlite3.zig");

/// 真值库连接句柄。
pub const Database = binding.Db;

/// 打开（不存在则创建）位于 `path` 的数据库。
pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    return binding.Db.init(.{
        .mode = .{ .file = path_z },
        .open_flags = .{ .write = true, .create = true },
    });
}
