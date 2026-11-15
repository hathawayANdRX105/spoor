//! 图：邻接表 + 递归 CTE 多跳遍历。派生索引，可从 truth 重建。
//! 所有 SQL 走 sqlite 动态 API（`?` 占位符 + 位置 tuple 绑定）。

const std = @import("std");
const Database = @import("sqlite.zig").Database;

/// 图节点。
pub const Node = struct {
    id: u64,
    label: []const u8,
};

/// 有向带类型边。
pub const Edge = struct {
    from_id: u64,
    to_id: u64,
    etype: []const u8,
};

/// 遍历结果：节点 id 及其距离起点的深度。
pub const WalkNode = struct {
    id: u64,
    depth: u32,
};

/// 建立图 schema（幂等建表）。
pub fn migrate(db: *Database) !void {
    try db.execDynamic("CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY, label TEXT NOT NULL);", .{}, .{});
    try db.execDynamic("CREATE TABLE IF NOT EXISTS edges (from_id INTEGER NOT NULL, to_id INTEGER NOT NULL, type TEXT NOT NULL);", .{}, .{});
}

/// 写入节点，返回新行 id。
pub fn insertNode(db: *Database, label: []const u8) !u64 {
    try db.execDynamic("INSERT INTO nodes (label) VALUES (?)", .{}, .{ label });
    return @intCast(db.getLastInsertRowID());
}

/// 写入有向边。
pub fn insertEdge(db: *Database, from_id: u64, to_id: u64, etype: []const u8) !void {
    try db.execDynamic("INSERT INTO edges (from_id, to_id, type) VALUES (?, ?, ?)", .{}, .{ from_id, to_id, etype });
}

/// 一跳邻居（按边类型过滤）。
pub fn neighbors(db: *Database, node_id: u64, etype: []const u8, allocator: std.mem.Allocator) ![]u64 {
    var stmt = try db.prepareDynamic("SELECT to_id AS id FROM edges WHERE from_id = ? AND type = ?");
    defer stmt.deinit();
    const rows = try stmt.all(struct { id: u64 }, allocator, .{}, .{ node_id, etype });
    defer allocator.free(rows);
    const ids = try allocator.alloc(u64, rows.len);
    for (rows, 0..) |row, i| ids[i] = row.id;
    return ids;
}

/// 递归 CTE 多跳遍历：从 start_id 出发，最多 max_depth 跳，仅走 type = etype 的边。
pub fn walk(db: *Database, start_id: u64, max_depth: u32, etype: []const u8, allocator: std.mem.Allocator) ![]WalkNode {
    const query = "WITH RECURSIVE walk(id, depth) AS (SELECT ?, 0 UNION ALL SELECT e.to_id, walk.depth + 1 FROM walk JOIN edges e ON walk.id = e.from_id WHERE walk.depth < ? AND e.type = ?) SELECT DISTINCT id, depth FROM walk";
    var stmt = try db.prepareDynamic(query);
    defer stmt.deinit();
    return try stmt.all(WalkNode, allocator, .{}, .{ start_id, max_depth, etype });
}

test {
    _ = @import("graph_test.zig");
}
