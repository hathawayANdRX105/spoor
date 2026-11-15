//! 混合检索：单轮编排「三臂 → RRF 融合 → judge rerank」。
//! harness 的多步循环只负责轮次控制，单轮内的检索编排下沉到这里。

const std = @import("std");
const spoor = @import("spoor");

/// 单轮混合检索的输入。
pub const Query = struct {
    /// 查询文本。
    text: []const u8,
    /// 图扩展的种子（通常是上一轮首个命中；0 = 不做图扩展）。
    graph_seed: u64 = 0,
    /// 图扩展的边类型（空 = 默认 links）。
    edge_type: []const u8 = "links",
    /// 图扩展跳数。
    graph_depth: u32 = 1,
    /// 向量检索用（空 = 不走向量臂）。
    query_embedding: ?[]align(1) const f32 = null,
};

/// 单轮混合检索的产出。
pub const Result = struct {
    /// 融合 + rerank 后的 chunk id（降序）。
    chunk_ids: []const u64,
    /// judge 是否降级（失败/禁用 → 保留融合顺序）。
    judge_degraded: bool,
    /// 是否走了 judge rerank。
    judge_used: bool,
};

/// 单轮混合检索：lexical + vector + graph 三臂 → RRF → judge rerank。
pub fn hybridSearch(
    db: *spoor.store.Database,
    allocator: std.mem.Allocator,
    io: std.Io,
    judge_config: spoor.judge_mod.judge.Config,
    query: Query,
    top_k: usize,
) !Result {
    // --- 词法臂（FTS5 BM25）---
    const lexical_ids = try spoor.retrieve.arms.lexical.search(db, query.text, allocator);
    defer allocator.free(lexical_ids);

    // --- 向量臂（可选）---
    const vector_ids = if (query.query_embedding) |emb|
        try spoor.retrieve.arms.vector.search(db, emb, top_k, allocator)
    else
        try allocator.alloc(u64, 0);
    defer allocator.free(vector_ids);

    // --- 图臂（可选，从 seed 扩展）---
    const graph_ids = if (query.graph_seed != 0)
        try spoor.retrieve.arms.graph.search(db, query.graph_seed, query.edge_type, query.graph_depth, allocator)
    else
        try allocator.alloc(u64, 0);
    defer allocator.free(graph_ids);

    // --- RRF 融合（lexical + vector + graph）---
    const ranked = [_][]const u64{ lexical_ids, vector_ids, graph_ids };
    const fused_all = try spoor.retrieve.fusion.reciprocalRankFusion(allocator, &ranked, 60);
    defer allocator.free(fused_all);

    const n = @min(top_k, fused_all.len);
    const fused_final = try allocator.dupe(u64, fused_all[0..n]);
    errdefer allocator.free(fused_final);
    if (fused_final.len == 0) {
        return .{ .chunk_ids = fused_final, .judge_degraded = false, .judge_used = false };
    }

    // --- judge rerank ---
    const judge_on = spoor.judge_mod.judge.isEnabled(judge_config);
    if (!judge_on) {
        return .{ .chunk_ids = fused_final, .judge_degraded = false, .judge_used = false };
    }

    var candidates = try allocator.alloc(spoor.judge_mod.judge.Candidate, fused_final.len);
    defer allocator.free(candidates);
    var owned_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_ids.items) |s| allocator.free(s);
        owned_ids.deinit(allocator);
    }

    for (fused_final, 0..) |id, i| {
        var text_buf: []u8 = undefined;
        if (try spoor.store.truth.selectChunk(db, allocator, id)) |chunk| {
            defer allocator.free(chunk.text);
            text_buf = try allocator.dupe(u8, chunk.text);
        } else {
            text_buf = try allocator.dupe(u8, "");
        }
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "chunk_{d}", .{id});
        const owned_id = try allocator.dupe(u8, id_str);
        errdefer allocator.free(owned_id);
        try owned_ids.append(allocator, owned_id);
        candidates[i] = .{ .id = owned_id, .text = text_buf };
        defer allocator.free(text_buf);
    }

    const hits = spoor.judge_mod.judge.rerank(allocator, io, judge_config, query.text, candidates) catch {
        return .{ .chunk_ids = fused_final, .judge_degraded = true, .judge_used = false };
    };
    defer {
        for (hits) |h| allocator.free(h.id);
        allocator.free(hits);
    }

    if (spoor.judge_mod.judge.isNearZeroMiss(hits)) {
        // 整列 near-zero → 视为 miss：清空结果
        allocator.free(fused_final);
        return .{ .chunk_ids = &.{}, .judge_degraded = false, .judge_used = true };
    }

    // 按 judge 顺序重排 fused_final（chunk_<id> 匹配 hits[].id）
    var reordered = try allocator.alloc(u64, fused_final.len);
    errdefer allocator.free(reordered);
    var pos: usize = 0;
    for (hits) |h| {
        // 从 h.id 提取 chunk_id
        if (!std.mem.startsWith(u8, h.id, "chunk_")) continue;
        const id = std.fmt.parseInt(u64, h.id["chunk_".len..], 10) catch continue;
        for (fused_final) |fid| {
            if (fid == id) {
                reordered[pos] = fid;
                pos += 1;
                break;
            }
        }
    }
    // hits 未覆盖的 id（理论上都有）补在后面
    for (fused_final) |fid| {
        if (pos >= reordered.len) break;
        var found = false;
        for (reordered[0..pos]) |rid| {
            if (rid == fid) found = true;
        }
        if (!found) {
            reordered[pos] = fid;
            pos += 1;
        }
    }
    allocator.free(fused_final);
    return .{ .chunk_ids = reordered[0..pos], .judge_degraded = false, .judge_used = true };
}

test "hybridSearch lexical arm with no judge" {
    const allocator = std.testing.allocator;
    var db = try @import("spoor").store.sqlite.open(allocator, ":memory:");
    defer db.deinit();
    try @import("spoor").store.truth.migrate(&db);
    try @import("spoor").store.fts.migrate(&db);
    const doc = try @import("spoor").store.truth.insertDocument(&db, "d1");
    _ = try @import("spoor").store.truth.insertChunk(&db, doc, "transformer architecture");
    _ = try @import("spoor").store.truth.insertChunk(&db, doc, "log structured merge trees");

    const r = try hybridSearch(&db, allocator, undefined_io, .{}, .{ .text = "transformer" }, 5);
    defer allocator.free(r.chunk_ids);
    try std.testing.expect(r.chunk_ids.len >= 1);
    try std.testing.expect(!r.judge_degraded);
    try std.testing.expect(!r.judge_used);
}

const undefined_io: std.Io = undefined;