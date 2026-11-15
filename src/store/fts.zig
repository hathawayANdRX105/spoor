//! 全文检索（原型：LIKE 子串匹配，无 BM25 打分）。派生索引，从 truth 重建。

const std = @import("std");
const Database = @import("sqlite.zig").Database;

/// 关键词命中。
pub const Match = struct {
    chunk_id: u64,
    document_id: u64,
    text: []const u8,
};

/// 关键词检索：返回 text 包含 keyword 的 chunk，按 id 升序。
pub fn searchKeyword(db: *Database, keyword: []const u8, allocator: std.mem.Allocator) ![]Match {
    var stmt = try db.prepareDynamic("SELECT id, document_id, text FROM chunks WHERE text LIKE '%' || ? || '%' ORDER BY id");
    defer stmt.deinit();
    return try stmt.all(Match, allocator, .{}, .{keyword});
}

test "keyword search over chunks" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try @import("truth.zig").migrate(&db);

    const doc = try @import("truth.zig").insertDocument(&db, "d1");
    _ = try @import("truth.zig").insertChunk(&db, doc, "the transformer architecture");
    _ = try @import("truth.zig").insertChunk(&db, doc, "log-structured merge trees");

    const hits = try searchKeyword(&db, "transformer", allocator);
    defer {
        for (hits) |h| allocator.free(h.text);
        allocator.free(hits);
    }
    try std.testing.expectEqual(1, hits.len);
    try std.testing.expect(std.mem.indexOf(u8, hits[0].text, "transformer") != null);

    const none = try searchKeyword(&db, "quantum", allocator);
    defer {
        for (none) |h| allocator.free(h.text);
        allocator.free(none);
    }
    try std.testing.expectEqual(0, none.len);
}
