//! 评测用例：检索质量的 golden 用例（query → 期望命中的 chunk id 集合）。
//! 评测跑在内存库上，确定性、无网络。

const std = @import("std");
const spoor = @import("spoor");

/// 一条评测用例：语料 + query + 期望命中的 chunk id。
pub const Case = struct {
    name: []const u8,
    /// 语料（每项为一条 chunk 文本，按序插入同一 document）。
    corpus: []const []const u8,
    /// 查询文本。
    query: []const u8,
    /// 期望命中的 chunk id（1 基，按插入序）。
    expect_ids: []const u64,
    /// 期望命中数上限（recall 门槛：命中数 ≥ 此值算过）。
    min_hits: usize,
};

/// 用例集（原型：3 条，覆盖词法、图扩展、无命中）。
pub const cases = [_]Case{
    .{
        .name = "lexical_basic",
        .corpus = &[_][]const u8{
            "the transformer architecture uses self-attention",
            "log structured merge trees optimize writes",
        },
        .query = "transformer",
        .expect_ids = &[_]u64{1},
        .min_hits = 1,
    },
    .{
        .name = "lexical_multi_hit",
        .corpus = &[_][]const u8{
            "retrieval augmented generation combines search",
            "vector search uses embeddings",
            "graph traversal follows edges",
        },
        .query = "search",
        .expect_ids = &[_]u64{1},
        .min_hits = 1,
    },
    .{
        .name = "lexical_no_hit",
        .corpus = &[_][]const u8{
            "the transformer architecture",
        },
        .query = "quantum entanglement",
        .expect_ids = &[_]u64{},
        .min_hits = 0,
    },
};

/// 跑一条用例：建内存库 → 插语料 → hybridSearch → 对照 expect。
pub const Outcome = struct {
    case_name: []const u8,
    passed: bool,
    hits: usize,
    detail: []const u8,
};

/// 跑全部用例，返回逐条结果。
pub fn runAll(allocator: std.mem.Allocator) ![]Outcome {
    var out: std.ArrayList(Outcome) = .empty;
    errdefer out.deinit(allocator);

    for (cases) |case| {
        const outcome = try runCase(allocator, case);
        try out.append(allocator, outcome);
    }
    return try out.toOwnedSlice(allocator);
}

fn runCase(allocator: std.mem.Allocator, case: Case) !Outcome {
    var db = try spoor.store.sqlite.open(allocator, ":memory:");
    defer db.deinit();
    try spoor.store.truth.migrate(&db);
    try spoor.store.fts.migrate(&db);

    const doc = try spoor.store.truth.insertDocument(&db, "eval-doc");
    for (case.corpus) |text| {
        _ = try spoor.store.truth.insertChunk(&db, doc, text);
    }

    const r = try spoor.retrieve.hybrid.hybridSearch(&db, allocator, dummy_io, .{}, .{
        .text = case.query,
    }, 10);
    defer allocator.free(r.chunk_ids);

    // 期望 id 全部命中（集合对照）
    var all_expected = true;
    for (case.expect_ids) |want| {
        var found = false;
        for (r.chunk_ids) |got| {
            if (got == want) found = true;
        }
        if (!found) all_expected = false;
    }
    const passed = r.chunk_ids.len >= case.min_hits and all_expected;
    return .{
        .case_name = case.name,
        .passed = passed,
        .hits = r.chunk_ids.len,
        .detail = if (passed) "" else if (!all_expected) "expected ids missing" else "hits below min_hits",
    };
}

const dummy_io: std.Io = undefined;

test "eval cases pass" {
    const allocator = std.testing.allocator;
    const outcomes = try runAll(allocator);
    defer {
        for (outcomes) |o| allocator.free(o.detail);
        allocator.free(outcomes);
    }
    for (outcomes) |o| {
        try std.testing.expect(o.passed);
    }
}