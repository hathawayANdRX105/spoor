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

test "insert nodes/edges, neighbors, and recursive walk" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try migrate(&db);

    const a = try insertNode(&db, "A");
    const b = try insertNode(&db, "B");
    const c = try insertNode(&db, "C");
    try insertEdge(&db, a, b, "links");
    try insertEdge(&db, b, c, "links");

    // 一跳邻居：A -> {B}
    const first = try neighbors(&db, a, "links", allocator);
    defer allocator.free(first);
    try std.testing.expectEqual(1, first.len);
    try std.testing.expect(first[0] == b);

    // 不匹配的边类型：空
    const none = try neighbors(&db, a, "replies", allocator);
    defer allocator.free(none);
    try std.testing.expectEqual(0, none.len);

    // 2-hop 遍历：A(0), B(1), C(2)
    const walked = try walk(&db, a, 2, "links", allocator);
    defer allocator.free(walked);
    try std.testing.expectEqual(3, walked.len);

    var found_a: bool = false;
    var found_b: bool = false;
    var found_c: bool = false;
    for (walked) |w| {
        if (w.id == a and w.depth == 0) found_a = true;
        if (w.id == b and w.depth == 1) found_b = true;
        if (w.id == c and w.depth == 2) found_c = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
    try std.testing.expect(found_c);

    // 1-hop 只到 B
    const shallow = try walk(&db, a, 1, "links", allocator);
    defer allocator.free(shallow);
    try std.testing.expectEqual(2, shallow.len);

    // 不存在的起点：只有起点自身，depth 0
    const lone = try walk(&db, 9999, 3, "links", allocator);
    defer allocator.free(lone);
    try std.testing.expectEqual(1, lone.len);
    try std.testing.expect(lone[0].id == 9999 and lone[0].depth == 0);
}
