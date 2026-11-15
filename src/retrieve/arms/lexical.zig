//! 词法检索臂：FTS5 BM25 匹配，返回 chunk_id 列表（按相关度降序）。

const std = @import("std");
const spoor = @import("spoor");

pub fn search(db: *spoor.store.Database, keyword: []const u8, allocator: std.mem.Allocator) ![]u64 {
    const matches = try spoor.store.fts.searchKeyword(db, keyword, allocator);
    defer {
        for (matches) |m| allocator.free(m.text);
        allocator.free(matches);
    }
    const ids = try allocator.alloc(u64, matches.len);
    for (matches, 0..) |m, i| ids[i] = m.chunk_id;
    return ids;
}
