//! 向量检索臂：flat cosine，返回 top-k chunk_id 列表（按相似度降序）。

const std = @import("std");
const spoor = @import("spoor");

pub fn search(db: *spoor.store.Database, query: []align(1) const f32, k: usize, allocator: std.mem.Allocator) ![]u64 {
    const scored = try spoor.store.vector.search(db, query, k, allocator);
    defer allocator.free(scored);
    const ids = try allocator.alloc(u64, scored.len);
    for (scored, 0..) |s, i| ids[i] = s.chunk_id;
    return ids;
}
