//! 工具注册与调用：调查 harness 的工具集。
//! 每个工具 = 名字 + 调用函数（query → 结果文本）。

const std = @import("std");
const spoor = @import("spoor");

/// 工具调用上下文。
pub const Ctx = struct {
    db: *spoor.store.Database,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
};

/// 工具调用结果。
pub const CallResult = struct {
    /// 结果文本（调用方负责 free）。
    text: []const u8,
};

/// 工具函数签名。
pub const ToolFn = *const fn (ctx: Ctx, query: []const u8) anyerror!CallResult;

/// 一个工具。
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    run: ToolFn,
};

/// 工具集：recall（本地检索）+ websearch（网络搜索）。
pub const Toolset = struct {
    tools: []const Tool,

    pub fn find(self: Toolset, name: []const u8) ?Tool {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn call(self: Toolset, ctx: Ctx, name: []const u8, query: []const u8) !CallResult {
        const tool = self.find(name) orelse return error.ToolNotFound;
        return try tool.run(ctx, query);
    }
};

/// 默认工具集。
pub const default_tools = [_]Tool{
    .{ .name = "recall", .description = "本地检索（FTS5 BM25 + 图扩展）", .run = recallTool },
    .{ .name = "websearch", .description = "网络搜索（SearXNG）", .run = websearchTool },
};

fn recallTool(ctx: Ctx, query: []const u8) !CallResult {
    const r = try spoor.retrieve.hybrid.hybridSearch(ctx.db, ctx.allocator, ctx.io, .{}, .{
        .text = query,
    }, 5);
    defer ctx.allocator.free(r.chunk_ids);

    var w = std.Io.Writer.Allocating.init(ctx.allocator);
    defer w.deinit();
    for (r.chunk_ids) |id| {
        if (try spoor.store.truth.selectChunk(ctx.db, ctx.allocator, id)) |c| {
            defer ctx.allocator.free(c.text);
            try w.writer.print("[chunk {d}] {s}\\n", .{ c.id, c.text });
        }
    }
    return .{ .text = try w.toOwnedSlice() };
}

fn websearchTool(ctx: Ctx, query: []const u8) !CallResult {
    const url = ctx.environ_map.get("SPOOR_WEBSEARCH_URL") orelse "";
    const results = spoor.websearch.client.search(ctx.allocator, ctx.io, .{ .base_url = url }, query) catch |err| {
        var w = std.Io.Writer.Allocating.init(ctx.allocator);
        defer w.deinit();
        try w.writer.print("websearch failed: {s}\\n", .{@errorName(err)});
        return .{ .text = try w.toOwnedSlice() };
    };
    defer {
        for (results) |r| {
            ctx.allocator.free(r.title);
            ctx.allocator.free(r.url);
            ctx.allocator.free(r.snippet);
        }
        ctx.allocator.free(results);
    }
    var w = std.Io.Writer.Allocating.init(ctx.allocator);
    defer w.deinit();
    for (results) |r| {
        try w.writer.print("{s}\\n  {s}\\n", .{ r.title, r.url });
    }
    return .{ .text = try w.toOwnedSlice() };
}

test "toolset find and call recall" {
    const allocator = std.testing.allocator;
    var db = try spoor.store.sqlite.open(allocator, ":memory:");
    defer db.deinit();
    try spoor.store.truth.migrate(&db);
    try spoor.store.fts.migrate(&db);
    const doc = try spoor.store.truth.insertDocument(&db, "d1");
    _ = try spoor.store.truth.insertChunk(&db, doc, "the transformer architecture");

    const ts = Toolset{ .tools = &default_tools };
    const found = ts.find("recall");
    try std.testing.expect(found != null);
    try std.testing.expect(ts.find("nope") == null);

    const ctx: Ctx = .{ .db = &db, .allocator = allocator, .io = undefined, .environ_map = undefined };
    const res = try ts.call(ctx, "recall", "transformer");
    defer allocator.free(res.text);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "transformer") != null);
}

test "toolset call unknown returns ToolNotFound" {
    const allocator = std.testing.allocator;
    var db = try spoor.store.sqlite.open(allocator, ":memory:");
    defer db.deinit();
    const ts = Toolset{ .tools = &default_tools };
    const ctx: Ctx = .{ .db = &db, .allocator = allocator, .io = undefined, .environ_map = undefined };
    const res = ts.call(ctx, "nope", "q");
    try std.testing.expectError(error.ToolNotFound, res);
}