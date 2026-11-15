//! 全文检索（FTS5 + BM25 打分）。派生索引，从 truth 重建。
//! chunks_fts 为 external-content 虚表：文本只在 chunks 存一份，
//! 通过触发器与 chunks 表同步；bm25() 打分降序即相关度升序。

const std = @import("std");
const Database = @import("sqlite.zig").Database;

/// 关键词命中。score 为 BM25 负相关度（越大越相关，取反后便于统一比较）。
pub const Match = struct {
    chunk_id: u64,
    document_id: u64,
    text: []const u8,
    score: f64,
};

/// 建立全文索引 schema（幂等）：external-content FTS5 表 + 同步触发器。
pub fn migrate(db: *Database) !void {
    try db.execDynamic(
        "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text, content='chunks', content_rowid='id');",
        .{}, .{},
    );
    try db.execDynamic(
        "CREATE TRIGGER IF NOT EXISTS chunks_fts_ai AFTER INSERT ON chunks BEGIN" ++
            " INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text); END;",
        .{}, .{},
    );
    try db.execDynamic(
        "CREATE TRIGGER IF NOT EXISTS chunks_fts_ad AFTER DELETE ON chunks BEGIN" ++
            " INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text); END;",
        .{}, .{},
    );
    try db.execDynamic(
        "CREATE TRIGGER IF NOT EXISTS chunks_fts_au AFTER UPDATE OF text ON chunks BEGIN" ++
            " INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text);" ++
            " INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text); END;",
        .{}, .{},
    );
}

/// 把用户关键词转成 FTS5 MATCH 查询：按空白拆词，双引号包裹，OR 连接（召回优先）。
pub fn matchQuery(allocator: std.mem.Allocator, keyword: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, keyword, " \t\r\n");
    var first = true;
    while (it.next()) |word| {
        if (!first) try out.appendSlice(allocator, " OR ");
        first = false;
        try out.append(allocator, '"');
        // FTS5 短语内：双引号翻倍转义
        var w = word;
        while (std.mem.indexOfScalar(u8, w, '"')) |q| {
            try out.appendSlice(allocator, w[0 .. q + 1]);
            try out.append(allocator, '"');
            w = w[q + 1 ..];
        }
        try out.appendSlice(allocator, w);
        try out.append(allocator, '"');
    }
    if (first) return error.EmptyQuery;
    return try out.toOwnedSlice(allocator);
}

/// 关键词检索（BM25 排序：相关度降序）。
pub fn searchKeyword(db: *Database, keyword: []const u8, allocator: std.mem.Allocator) ![]Match {
    const mq = matchQuery(allocator, keyword) catch |err| switch (err) {
        error.EmptyQuery => return &.{},
        else => return err,
    };
    defer allocator.free(mq);

    var stmt = try db.prepareDynamic(
        "SELECT c.id, c.document_id, c.text, -bm25(chunks_fts) FROM chunks_fts f " ++
            "JOIN chunks c ON c.id = f.rowid WHERE chunks_fts MATCH ? ORDER BY rank",
    );
    defer stmt.deinit();
    return try stmt.all(Match, allocator, .{}, .{mq});
}

test {
    _ = @import("fts_test.zig");
}
