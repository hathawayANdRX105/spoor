//! SQLite 连接 / 事务 / 迁移封装。所有存储都走这一层。

const std = @import("std");
const zsql = @import("sqlite");

/// 真值库连接句柄——zig-sqlite Db 的薄封装。
pub const Database = zsql.Db;

/// 打开（不存在则创建）位于 `path` 的数据库。
pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return zsql.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{ .write = true, .create = true },
    });
}
