//! 存储层入口：SQLite 真值 + 派生索引。
//!
//! 真值（truth）是唯一 commit point；fts/vector/graph 是派生索引，可重建。

const std = @import("std");

pub const sqlite = @import("sqlite.zig");
pub const truth = @import("truth.zig");
pub const fts = @import("fts.zig");
pub const vector = @import("vector.zig");
pub const graph = @import("graph.zig");
pub const timeseries = @import("timeseries.zig");

pub const Database = sqlite.Database;

/// 打开（不存在则创建）位于 `path` 的真值数据库并完成 schema 迁移。
pub fn openDatabase(allocator: std.mem.Allocator, path: []const u8) !Database {
    var db = try sqlite.open(allocator, path);
    errdefer db.deinit();
    try truth.migrate(&db);
    try graph.migrate(&db);
    try vector.migrate(&db);
    try timeseries.migrate(&db);
    return db;
}

test {
    _ = sqlite;
    _ = truth;
    _ = fts;
    _ = vector;
    _ = graph;
    _ = timeseries;
}
