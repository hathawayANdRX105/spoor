//! 评测判定：把 judge rerank 作为评测的一部分——对检索结果做相关度判定。
//! 与 src/judge/（能力层）分开：这里是评测入口，消费 judge 能力。

const std = @import("std");
const spoor = @import("spoor");

/// 对一组检索结果跑 judge 相关度判定（评测模式）。
/// 返回每条的相关度（0..1）；judge 禁用时返回空（评测跳过 judge 轴）。
pub fn judgeRelevance(
    allocator: std.mem.Allocator,
    io: std.Io,
    judge_config: spoor.judge_mod.judge.Config,
    query: []const u8,
    chunk_ids: []const u64,
) ![]spoor.judge_mod.judge.Hit {
    if (!spoor.judge_mod.judge.isEnabled(judge_config)) return &.{};

    var candidates = try allocator.alloc(spoor.judge_mod.judge.Candidate, chunk_ids.len);
    defer allocator.free(candidates);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    for (chunk_ids, 0..) |id, i| {
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "chunk_{d}", .{id});
        const oid = try allocator.dupe(u8, id_str);
        try owned.append(allocator, oid);
        candidates[i] = .{ .id = oid, .text = "" };
    }
    return try spoor.judge_mod.judge.rerank(allocator, io, judge_config, query, candidates);
}

test "judge relevance disabled returns empty" {
    const allocator = std.testing.allocator;
    const hits = try judgeRelevance(allocator, dummy_io, .{}, "q", &[_]u64{1});
    defer allocator.free(hits);
    try std.testing.expectEqual(0, hits.len);
}

const dummy_io: std.Io = undefined;