//! 图检索臂：从 seed 节点出发多跳遍历，返回可达节点 id 列表（按 depth 升序）。

const std = @import("std");
const spoor = @import("spoor");

pub fn search(db: *spoor.store.Database, seed_id: u64, etype: []const u8, max_depth: u32, allocator: std.mem.Allocator) ![]u64 {
    const walked = try spoor.store.graph.walk(db, seed_id, max_depth, etype, allocator);
    defer allocator.free(walked);
    const ids = try allocator.alloc(u64, walked.len);
    for (walked, 0..) |w, i| ids[i] = w.id;
    return ids;
}
