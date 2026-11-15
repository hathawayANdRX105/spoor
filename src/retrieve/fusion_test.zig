//! fusion（从主文件拆出）。

const std = @import("std");
const impl = @import("fusion.zig");

test "rrf fusion ranks shared ids first" {
    const allocator = std.testing.allocator;
    const l1 = [_]u64{ 1, 2, 3 };
    const l2 = [_]u64{ 2, 3, 4 };
    const ranked = [_][]const u64{ &l1, &l2 };

    const fused = try impl.reciprocalRankFusion(allocator, &ranked, 60);
    defer allocator.free(fused);

    try std.testing.expect(fused.len >= 4);
    // 2 同时出现在两个列表靠前位置，应排最前
    try std.testing.expect(fused[0] == 2);
}
