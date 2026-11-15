//! 向量检索（原型：flat cosine 暴力扫描，无 ANN）。派生索引，从 truth 重建。

const std = @import("std");
const Database = @import("sqlite.zig").Database;

/// 相似度结果。
pub const Scored = struct {
    chunk_id: u64,
    score: f32,
};

/// 建立向量 schema（幂等）。
pub fn migrate(db: *Database) !void {
    try db.execDynamic("CREATE TABLE IF NOT EXISTS vectors (chunk_id INTEGER PRIMARY KEY, embedding BLOB NOT NULL);", .{}, .{});
}

/// 写入 chunk 的 embedding（f32 数组序列化为 BLOB）。同维度假设由调用方保证。
pub fn insertVector(db: *Database, chunk_id: u64, embedding: []const f32) !void {
    const bytes = std.mem.sliceAsBytes(embedding);
    try db.execDynamic("INSERT OR REPLACE INTO vectors (chunk_id, embedding) VALUES (?, ?)", .{}, .{ chunk_id, bytes });
}

/// flat cosine 检索：返回 top-k 最相似 chunk，按相似度降序。
pub fn search(db: *Database, query: []const f32, k: usize, allocator: std.mem.Allocator) ![]Scored {
    var stmt = try db.prepareDynamic("SELECT chunk_id, embedding FROM vectors");
    defer stmt.deinit();
    const rows = try stmt.all(struct { chunk_id: u64, embedding: []const u8 }, allocator, .{}, .{});
    defer {
        for (rows) |r| allocator.free(r.embedding);
        allocator.free(rows);
    }

    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(allocator);
    for (rows) |row| {
        const emb = std.mem.bytesAsSlice(f32, row.embedding);
        const s = cosineSimilarity(query, emb);
        try scored.append(allocator, .{ .chunk_id = row.chunk_id, .score = s });
    }

    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const n = @min(k, scored.items.len);
    return try allocator.dupe(Scored, scored.items[0..n]);
}

/// 余弦相似度（假设等长，长度由调用方保证）。
pub fn cosineSimilarity(a: []align(1) const f32, b: []align(1) const f32) f32 {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (a, b) |x, y| {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if (na == 0 or nb == 0) return 0;
    return dot / (std.math.sqrt(na) * std.math.sqrt(nb));
}

test "flat cosine search" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try migrate(&db);

    try insertVector(&db, 1, &[_]f32{ 1, 0, 0 });
    try insertVector(&db, 2, &[_]f32{ 0, 1, 0 });
    try insertVector(&db, 3, &[_]f32{ 1, 1, 0 });

    const top = try search(&db, &[_]f32{ 1, 0, 0 }, 2, allocator);
    defer allocator.free(top);
    try std.testing.expectEqual(2, top.len);
    try std.testing.expect(top[0].chunk_id == 1);
    try std.testing.expect(top[0].score > top[1].score);
}
