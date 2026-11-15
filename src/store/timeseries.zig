//! 时序：普通表 + 时间戳。真值的一部分（事件流）。

const std = @import("std");
const Database = @import("sqlite.zig").Database;

/// 一条带时间戳的事件。
pub const Event = struct {
    id: u64,
    timestamp: i64,
    kind: []const u8,
    payload: []const u8,
};

/// 建立时序 schema（幂等）。
pub fn migrate(db: *Database) !void {
    try db.execDynamic("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, timestamp INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL);", .{}, .{});
}

/// 追加一条事件，返回新行 id。
pub fn append(db: *Database, timestamp: i64, kind: []const u8, payload: []const u8) !u64 {
    try db.execDynamic("INSERT INTO events (timestamp, kind, payload) VALUES (?, ?, ?)", .{}, .{ timestamp, kind, payload });
    return @intCast(db.getLastInsertRowID());
}

/// 按时间范围查询事件（闭区间），按时间戳升序。
pub fn range(db: *Database, from_ts: i64, to_ts: i64, allocator: std.mem.Allocator) ![]Event {
    var stmt = try db.prepareDynamic("SELECT id, timestamp, kind, payload FROM events WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp");
    defer stmt.deinit();
    return try stmt.all(Event, allocator, .{}, .{ from_ts, to_ts });
}

test "append and range query" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try migrate(&db);

    _ = try append(&db, 100, "ingest", "doc-1");
    _ = try append(&db, 200, "ingest", "doc-2");
    _ = try append(&db, 300, "recall", "query-1");

    const evs = try range(&db, 150, 350, allocator);
    defer {
        for (evs) |e| {
            allocator.free(e.kind);
            allocator.free(e.payload);
        }
        allocator.free(evs);
    }
    try std.testing.expectEqual(2, evs.len);
    try std.testing.expect(evs[0].timestamp == 200);
    try std.testing.expect(evs[1].timestamp == 300);
}
