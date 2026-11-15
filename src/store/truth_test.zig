//! truth（从主文件拆出）。

const std = @import("std");
const impl = @import("truth.zig");

test "insert and select document/chunk/fact" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try impl.migrate(&db);

    const doc_id = try impl.insertDocument(&db, "title-1");
    _ = try impl.insertChunk(&db, doc_id, "chunk text a");
    _ = try impl.insertChunk(&db, doc_id, "chunk text b");
    const fact_id = try impl.insertFact(&db, "subject-1", "relation-1", "object-1");
    try std.testing.expect(fact_id > 0);

    const doc = try impl.selectDocument(&db, allocator, doc_id);
    if (doc) |d| {
        defer allocator.free(d.title);
        try std.testing.expect(d.id == doc_id);
        try std.testing.expect(std.mem.eql(u8, d.title, "title-1"));
    } else {
        @panic("expected document");
    }

    const doc_missing = try impl.selectDocument(&db, allocator, 999999);
    try std.testing.expect(doc_missing == null);

    const chunks = try impl.selectChunksByDocument(&db, doc_id, allocator);
    defer {
        for (chunks) |c| allocator.free(c.text);
        allocator.free(chunks);
    }
    try std.testing.expectEqual(2, chunks.len);
    try std.testing.expect(chunks[0].id < chunks[1].id);
    try std.testing.expect(std.mem.eql(u8, chunks[0].text, "chunk text a"));
    try std.testing.expect(std.mem.eql(u8, chunks[1].text, "chunk text b"));
    for (chunks) |c| {
        try std.testing.expect(c.document_id == doc_id);
    }
}
