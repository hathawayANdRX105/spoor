//! 调查代理：多步调查循环 + judge rerank + websearch + 融合。
//!
//! 单轮（R1）：query → 三臂检索 → RRF 融合
//! 多步（R2）：对每轮 top 结果抽取「下一问」关键词（图邻居 / FTS 词），再查，
//!           合并去重，直到深度上限或无新结果。

const std = @import("std");
const spoor = @import("spoor");

pub const Options = struct {
    /// 调查深度（最大轮数）。
    max_rounds: usize = 3,
    /// 每轮保留的融合结果数。
    top_k: usize = 5,
    /// 图扩展跳数。
    graph_depth: u32 = 1,
    /// websearch 关键词（空 = 不用 web）。
    websearch_url: []const u8 = "",
};

/// 一轮调查的产出。
pub const Round = struct {
    round: usize,
    query: []const u8,
    chunk_ids: []const u64,
};

/// 调查报告。
pub const Report = struct {
    rounds: []Round,
    /// judge rerank 是否降级（失败/禁用）。
    judge_degraded: bool,
    /// websearch 是否执行成功。
    web_ok: bool,
    /// web 结果数。
    web_count: usize,
};

/// 对 question 跑多步调查：每轮「检索 → 融合 → judge rerank → 从 top 结果的文本抽新词进下一轮」。
pub fn investigate(
    db: *spoor.store.Database,
    question: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) !Report {
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});

    const judge_config: spoor.judge_mod.judge.Config = .{
        .endpoint = environ_map.get("SPOOR_JUDGE_URL") orelse "",
        .model = environ_map.get("SPOOR_JUDGE_MODEL") orelse "spoor-judge",
        .api_key = environ_map.get("SPOOR_JUDGE_KEY") orelse "",
    };
    const judge_on = spoor.judge_mod.judge.isEnabled(judge_config);

    var opts: Options = .{};
    if (environ_map.get("SPOOR_MAX_ROUNDS")) |v| {
        opts.max_rounds = std.fmt.parseInt(usize, v, 10) catch opts.max_rounds;
    }

    var all_rounds: std.ArrayList(Round) = .empty;
    errdefer {
        for (all_rounds.items) |*r| {
            allocator.free(r.query);
            allocator.free(r.chunk_ids);
        }
        all_rounds.deinit(allocator);
    }

    var seen_ids = std.AutoHashMap(u64, void).init(allocator);
    defer seen_ids.deinit();

    var current_query = try allocator.dupe(u8, question);
    var judge_degraded = false;
    var web_ok = false;
    var web_count: usize = 0;
    defer allocator.free(current_query);

    var round_idx: usize = 0;
    while (round_idx < opts.max_rounds) : (round_idx += 1) {
        // --- 词法臂（FTS5 BM25）---
        const lexical_ids = try spoor.retrieve.arms.lexical.search(db, current_query, allocator);
        defer allocator.free(lexical_ids);

        // --- 图臂：从上轮首个命中出发扩展 ---
        const graph_ids = if (lexical_ids.len > 0)
            try spoor.retrieve.arms.graph.search(db, lexical_ids[0], "links", opts.graph_depth, allocator)
        else
            try allocator.alloc(u64, 0);
        defer allocator.free(graph_ids);

        // --- RRF 融合（lexical + graph；去重已见 id）---
        const ranked = [_][]const u64{ lexical_ids, graph_ids };
        const fused_all = try spoor.retrieve.fusion.reciprocalRankFusion(allocator, &ranked, 60);
        defer allocator.free(fused_all);

        var fused = try allocator.alloc(u64, @min(opts.top_k, fused_all.len));
        var fused_len: usize = 0;
        defer allocator.free(fused);
        for (fused_all) |id| {
            if (seen_ids.contains(id)) continue;
            if (fused_len == fused.len) break;
            fused[fused_len] = id;
            fused_len += 1;
            seen_ids.put(id, {}) catch {};
        }
        const fused_final = fused[0..fused_len];
        if (fused_final.len == 0) break; // 无新结果，停止

        // --- judge rerank（拉取 chunk 文本，判定相关度；失败降级）---
        var candidates = try allocator.alloc(spoor.judge_mod.judge.Candidate, fused_final.len);
        defer allocator.free(candidates);
        var id_strings: std.ArrayList([]u8) = .empty;
        defer {
            for (id_strings.items) |s| allocator.free(s);
            id_strings.deinit(allocator);
        }
        var texts = std.ArrayList([]u8).empty;
        defer {
            for (texts.items) |t| allocator.free(t);
            texts.deinit(allocator);
        }

        for (fused_final, 0..) |id, i| {
            var text_buf: []u8 = "";
            if (try spoor.store.truth.selectChunk(db, allocator, id)) |chunk| {
                defer allocator.free(chunk.text);
                text_buf = try allocator.dupe(u8, chunk.text);
            } else {
                text_buf = try allocator.dupe(u8, "");
            }
            try texts.append(allocator, text_buf);
            var id_buf: [32]u8 = undefined;
            const id_str = try std.fmt.bufPrint(&id_buf, "chunk_{d}", .{id});
            const owned_id = try allocator.dupe(u8, id_str);
            try id_strings.append(allocator, owned_id);
            candidates[i] = .{ .id = owned_id, .text = text_buf };
        }

        const final_order = try allocator.dupe(u64, fused_final);
        defer allocator.free(final_order);

        if (judge_on) {
            const hits = spoor.judge_mod.judge.rerank(allocator, io, judge_config, current_query, candidates) catch |err| blk: {
                try stdout.interface.print("judge rerank 失败（{s}），降级保留融合顺序\n", .{@errorName(err)});
                judge_degraded = true;
                break :blk try spoor.judge_mod.judge.Mock.rerank(allocator, judge_config, current_query, candidates);
            };
            defer {
                for (hits) |h| allocator.free(h.id);
                allocator.free(hits);
            }

            if (spoor.judge_mod.judge.isNearZeroMiss(hits)) {
                try stdout.interface.print("第 {d} 轮 judge 判定整列 near-zero → 视为 miss\n", .{round_idx + 1});
                break;
            }

            // 按 judge 顺序重排 fused_final
            std.mem.sort(u64, final_order, hits, struct {
                fn idRank(hits2: []spoor.judge_mod.judge.Hit, id: u64) usize {
                    var key_buf: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&key_buf, "chunk_{d}", .{id}) catch return 9999;
                    for (hits2, 0..) |h, idx| {
                        if (std.mem.eql(u8, h.id, key)) return idx;
                    }
                    return 9999;
                }
                fn lessThan(hits2: []spoor.judge_mod.judge.Hit, a: u64, b: u64) bool {
                    return idRank(hits2, a) < idRank(hits2, b);
                }
            }.lessThan);
        }

        // 记录本轮
        const query_copy = try allocator.dupe(u8, current_query);
        const ids_copy = try allocator.dupe(u64, final_order);
        try all_rounds.append(allocator, .{
            .round = round_idx + 1,
            .query = query_copy,
            .chunk_ids = ids_copy,
        });

        try stdout.interface.print("第 {d} 轮（query: \"{s}\"）命中 {d} 个 chunk：\n", .{ round_idx + 1, current_query, fused_final.len });
        for (final_order) |id| {
            if (try spoor.store.truth.selectChunk(db, allocator, id)) |c| {
                defer allocator.free(c.text);
                try stdout.interface.print("  [chunk {d}] {s}\n", .{ c.id, c.text });
                // 下一轮 query：取本 chunk 文本的前 32 字节（原型式「下一问」抽取）
                if (round_idx + 1 < opts.max_rounds) {
                    const take = @min(c.text.len, 32);
                    const next_q = try nextQueryFrom(c.text[0..take], allocator);
                    allocator.free(current_query);
                    current_query = next_q;
                }
            }
        }

        // --- websearch（仅第一轮；失败降级）---
        if (round_idx == 0 and environ_map.get("SPOOR_NO_WEB") == null) {
            const web_results = spoor.websearch.client.search(allocator, io, .{ .base_url = opts.websearch_url }, current_query) catch |err| blk: {
                try stdout.interface.print("websearch 失败（{s}），仅本地结果\n", .{@errorName(err)});
                break :blk &.{};
            };
            defer {
                for (web_results) |r| {
                    allocator.free(r.title);
                    allocator.free(r.url);
                    allocator.free(r.snippet);
                }
                allocator.free(web_results);
            }
            web_ok = web_results.len > 0;
            web_count = web_results.len;
            if (web_ok) {
                try stdout.interface.print("web 结果 {d} 条：\n", .{web_results.len});
                for (web_results) |r| {
                    try stdout.interface.print("  {s}\n    {s}\n", .{ r.title, r.url });
                }
            }
        }
    }

    return .{
        .rounds = try all_rounds.toOwnedSlice(allocator),
        .judge_degraded = judge_degraded,
        .web_ok = web_ok,
        .web_count = web_count,
    };
}

/// 从 chunk 文本抽取下一轮 query（原型：取前 24 字节的词序列，词边界裁剪）。
fn nextQueryFrom(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const take = @min(text.len, 24);
    const trimmed = if (std.mem.lastIndexOfScalar(u8, text[0..take], ' ')) |sp|
        text[0..sp]
    else
        text[0..take];
    if (trimmed.len == 0) return try allocator.dupe(u8, text[0..@min(text.len, 8)]);
    return try allocator.dupe(u8, trimmed);
}
