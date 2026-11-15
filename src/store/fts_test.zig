//! fts（从主文件拆出）。

const std = @import("std");
const impl = @import("fts.zig");

test "fts5 bm25 search over chunks" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try @import("truth.zig").migrate(&db);
    try impl.migrate(&db);

    const doc = try @import("truth.zig").insertDocument(&db, "d1");
    _ = try @import("truth.zig").insertChunk(&db, doc, "the transformer architecture");
    _ = try @import("truth.zig").insertChunk(&db, doc, "log structured merge trees");
    _ = try @import("truth.zig").insertChunk(&db, doc, "transformer scaling laws");

    // 单词：两处 transformer 命中，bm25 相关度高的在前
    const hits = try impl.searchKeyword(&db, "transformer", allocator);
    defer {
        for (hits) |h| allocator.free(h.text);
        allocator.free(hits);
    }
    try std.testing.expectEqual(2, hits.len);
    try std.testing.expect(hits[0].score >= hits[1].score);

    // 多词 OR：三行都命中
    const multi = try impl.searchKeyword(&db, "transformer merge", allocator);
    defer {
        for (multi) |h| allocator.free(h.text);
        allocator.free(multi);
    }
    try std.testing.expectEqual(3, multi.len);

    // 无命中：空
    const none = try impl.searchKeyword(&db, "quantum", allocator);
    defer {
        for (none) |h| allocator.free(h.text);
        allocator.free(none);
    }
    try std.testing.expectEqual(0, none.len);
}
