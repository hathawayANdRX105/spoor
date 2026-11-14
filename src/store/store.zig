//! 存储层入口：SQLite 真值 + 派生索引。
//!
//! 真值（truth）是唯一 commit point；fts/vector/graph 是派生索引，可重建。
pub const sqlite = @import("sqlite.zig");
pub const Database = (@import("sqlite.zig")).Database;
pub const zsql = @import("sqlite");
pub const truth = @import("truth.zig");
pub const fts = @import("fts.zig");
pub const vector = @import("vector.zig");
pub const graph = @import("graph.zig");
pub const timeseries = @import("timeseries.zig");

/// 在已打开的 zig-sqlite 连接上建立真值层 schema（幂等建表）。
pub fn ensureSchema(db: *zsql.Db) !void {
    try db.exec(comptime "CREATE TABLE IF NOT EXISTS documents (id INTEGER PRIMARY KEY, title TEXT NOT NULL);", .{});
    try db.exec(comptime "CREATE TABLE IF NOT EXISTS chunks (id INTEGER PRIMARY KEY, document_id INTEGER NOT NULL, text TEXT NOT NULL);", .{});
    try db.exec(comptime "CREATE TABLE IF NOT EXISTS facts (id INTEGER PRIMARY KEY, subject TEXT NOT NULL, relation TEXT NOT NULL, object TEXT NOT NULL);", .{});
}

/// 打开（不存在则创建）位于 `path` 的真值数据库并完成 schema 迁移。
pub fn openDatabase(path: []const u8) !Database {
    const db = try Database.open(path);
    try db.migrate();
    return db;
}

test {
    _ = sqlite;
    _ = Database;
    _ = zsql;
    _ = truth;
    _ = fts;
    _ = vector;
    _ = graph;
    _ = timeseries;
}
