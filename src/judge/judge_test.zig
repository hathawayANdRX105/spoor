//! judge（从主文件拆出）。

const std = @import("std");
const impl = @import("judge.zig");
const Hit = impl.Hit;
const Candidate = impl.Candidate;
const Mock = impl.Mock;

test "mock rerank orders by relevance" {
    const allocator = std.testing.allocator;
    const candidates = [_]Candidate{
        .{ .id = "a", .text = "the transformer architecture" },
        .{ .id = "b", .text = "log structured merge trees" },
        .{ .id = "c", .text = "transformer scaling laws" },
    };
    const hits = try Mock.rerank(allocator, .{}, "transformer", &candidates);
    defer {
        for (hits) |h| allocator.free(h.id);
        allocator.free(hits);
    }
    // a 与 c 含 transformer（relevance 1.0），b 不含（0.0）
    try std.testing.expectEqual(3, hits.len);
    try std.testing.expect(hits[0].id[0] == 'a' or hits[0].id[0] == 'c');
    try std.testing.expect(hits[0].relevance > hits[2].relevance);
}

test "near-zero miss detection" {
    const hits = [_]Hit{
        .{ .id = "a", .relevance = 0.01 },
        .{ .id = "b", .relevance = 0.03 },
    };
    try std.testing.expect(impl.isNearZeroMiss(&hits));
    const good = [_]Hit{.{ .id = "a", .relevance = 0.9 }};
    try std.testing.expect(!impl.isNearZeroMiss(&good));
}
