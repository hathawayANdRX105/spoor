//! 调查代理：多步调查循环——轮次控制 + 下一问抽取 + websearch。
//! 单轮检索编排（三臂 → RRF → judge rerank）在 retrieve/hybrid.zig。

const std = @import("std");
const spoor = @import("spoor");

pub const Options = struct {
    /// 调查深度（最大轮数）。
    max_rounds: usize = 3,
    /// 每轮保留的融合结果数。
    top_k: usize = 5,
    /// 图扩展跳数。
    graph_depth: u32 = 1,
    /// websearch URL（空 = 不用 web）。
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
    /// judge rerank 是否降级（失败/禁用 → 保留融合顺序）。
    judge_degraded: bool,
    /// websearch 是否执行成功。
    web_ok: bool,
    /// web 结果数。
    web_count: usize,
};

/// 对 question 跑多步调查：每轮「hybridSearch → 从 top chunk 抽下一问」。
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

    var opts: Options = .{};
    if (environ_map.get("SPOOR_MAX_ROUNDS")) |v| {
        opts.max_rounds = std.fmt.parseInt(usize, v, 10) catch opts.max_rounds;
    }
    if (environ_map.get("SPOOR_WEBSEARCH_URL")) |v| opts.websearch_url = v;

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
    defer allocator.free(current_query);

    var judge_degraded = false;
    var web_ok = false;
    var web_count: usize = 0;

    var round_idx: usize = 0;
    while (round_idx < opts.max_rounds) : (round_idx += 1) {
        // --- 单轮检索编排（三臂 → RRF → judge rerank）下沉在 retrieve/hybrid ---
        const graph_seed: u64 = if (round_idx > 0) first_chunk_of(all_rounds.items[round_idx - 1].chunk_ids) else 0;
        const hr = try spoor.retrieve.hybrid.hybridSearch(db, allocator, io, judge_config, .{
            .text = current_query,
            .graph_seed = graph_seed,
            .edge_type = "links",
            .graph_depth = opts.graph_depth,
        }, opts.top_k);
        defer allocator.free(hr.chunk_ids);

        if (hr.judge_degraded) judge_degraded = true;

        // 去重（seen_ids 跨轮）
        var new_ids = try allocator.alloc(u64, hr.chunk_ids.len);
        errdefer allocator.free(new_ids);
        var new_len: usize = 0;
        for (hr.chunk_ids) |id| {
            if (seen_ids.contains(id)) continue;
            new_ids[new_len] = id;
            new_len += 1;
            seen_ids.put(id, {}) catch {};
        }
        const round_ids = new_ids[0..new_len];
        defer allocator.free(new_ids);

        if (round_ids.len == 0) break; // 无新结果，停止

        // 记录本轮
        const query_copy = try allocator.dupe(u8, current_query);
        const ids_copy = try allocator.dupe(u64, round_ids);
        try all_rounds.append(allocator, .{
            .round = round_idx + 1,
            .query = query_copy,
            .chunk_ids = ids_copy,
        });

        try stdout.interface.print("第 {d} 轮（query: \"{s}\"）命中 {d} 个 chunk：\n", .{ round_idx + 1, current_query, round_ids.len });
        for (round_ids) |id| {
            if (try spoor.store.truth.selectChunk(db, allocator, id)) |c| {
                defer allocator.free(c.text);
                try stdout.interface.print("  [chunk {d}] {s}\n", .{ c.id, c.text });
                if (round_idx + 1 < opts.max_rounds) {
                    const next_q = try nextQueryFrom(c.text, allocator);
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

fn first_chunk_of(ids: []const u64) u64 {
    return if (ids.len > 0) ids[0] else 0;
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