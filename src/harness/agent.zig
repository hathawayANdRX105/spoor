//! 调查代理：RAG 本体的最小编排——本地检索 + 图扩展 + RRF 融合 + websearch。

const std = @import("std");
const spoor = @import("spoor");

/// 对 question 跑一轮调查：本地多臂检索 + 融合，再尝试 websearch（失败降级）。
pub fn investigate(db: *spoor.store.Database, question: []const u8, allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !void {
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});

    // 1. 词法臂：关键词 LIKE
    const lexical_ids = try spoor.retrieve.arms.lexical.search(db, question, allocator);
    defer allocator.free(lexical_ids);

    // 2. 图臂：从第一个命中 chunk 出发做 1 跳扩展（无命中则跳过）
    const graph_ids = if (lexical_ids.len > 0)
        try spoor.retrieve.arms.graph.search(db, lexical_ids[0], "links", 1, allocator)
    else
        try allocator.alloc(u64, 0);
    defer allocator.free(graph_ids);

    // 3. RRF 融合
    const ranked = [_][]const u64{ lexical_ids, graph_ids };
    const fused = try spoor.retrieve.fusion.reciprocalRankFusion(allocator, &ranked, 60);
    defer allocator.free(fused);

    try stdout.interface.print("本地命中 {d} 个 chunk（融合后）：\n", .{fused.len});
    for (fused) |id| {
        if (try spoor.store.truth.selectChunk(db, allocator, id)) |c| {
            defer allocator.free(c.text);
            try stdout.interface.print("  [chunk {d}] {s}\n", .{ c.id, c.text });
        }
    }

    // 4. websearch（失败降级；SPOOR_NO_WEB=1 跳过，避免网络挂起）
    if (environ_map.get("SPOOR_NO_WEB") != null) {
        try stdout.interface.print("websearch 已跳过（SPOOR_NO_WEB 设置）\n", .{});
        return;
    }

    const results = spoor.websearch.client.search(allocator, io, question) catch |err| {
        try stdout.interface.print("websearch 失败（{s}），仅本地结果\n", .{@errorName(err)});
        return;
    };
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    try stdout.interface.print("web 结果 {d} 条：\n", .{results.len});
    for (results) |r| {
        try stdout.interface.print("  {s}\n    {s}\n", .{ r.title, r.url });
    }
}
