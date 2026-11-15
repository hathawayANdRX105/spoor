//! rerank（从主文件拆出）。

const std = @import("std");
const impl = @import("rerank.zig");

test "rerank identity" {
    const allocator = std.testing.allocator;
    const input = [_]u64{ 3, 1, 2 };
    const out = try impl.rerank(allocator, &input);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u64, &input, out);
}
