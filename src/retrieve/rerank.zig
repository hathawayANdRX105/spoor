//! 重排：原型阶段保持融合顺序（identity），后续接入 judge/模型打分。

const std = @import("std");

pub fn rerank(allocator: std.mem.Allocator, ids: []const u64) ![]u64 {
    return try allocator.dupe(u64, ids);
}

test {
    _ = @import("rerank_test.zig");
}
