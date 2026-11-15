//! 重排：原型阶段保持融合顺序（identity），后续接入 judge/模型打分。

const std = @import("std");

pub fn rerank(allocator: std.mem.Allocator, ids: []const u64) ![]u64 {
    return try allocator.dupe(u64, ids);
}

test "rerank identity" {
    const allocator = std.testing.allocator;
    const input = [_]u64{ 3, 1, 2 };
    const out = try rerank(allocator, &input);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u64, &input, out);
}
