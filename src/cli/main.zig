const std = @import("std");
const spoor = @import("spoor");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.fs.File.stdout().deprecatedWriter().print(
            \\spoor v{s} — 简化 RAG + 调查任务 harness
            \\用法：
            \\  spoor <db路径> [问题]          打开库并对问题跑一轮调查
            \\  spoor seed <db路径>           写入演示数据
            \\
        , .{spoor.version});
        return;
    }

    if (std.mem.eql(u8, args[1], "seed")) {
        if (args.len < 3) return error.MissingDbPath;
        var db = try spoor.store.openDatabase(allocator, args[2]);
        defer db.deinit();
        try seed(&db);
        return;
    }

    const path = args[1];
    const question = if (args.len > 2) args[2] else "";

    var db = try spoor.store.openDatabase(allocator, path);
    defer db.deinit();

    if (question.len == 0) {
        try std.fs.File.stdout().deprecatedWriter().print("spoor: opened {s}（无问题，退出）\n", .{path});
        return;
    }

    try spoor.harness.agent.investigate(&db, question, allocator);
}

fn seed(db: *spoor.store.Database) !void {
    const t = spoor.store.truth;
    const g = spoor.store.graph;

    const d1 = try t.insertDocument(db, "rag-intro");
    const c1 = try t.insertChunk(db, d1, "retrieval augmented generation combines search with language models");
    const c2 = try t.insertChunk(db, d1, "vector search uses embeddings to find similar text");

    // 图：c1 -> c2 通过 links 边（演示图扩展）
    _ = try g.insertNode(db, "chunk");
    _ = try g.insertEdge(db, c1, c2, "links");

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("已写入演示数据：doc={d} chunks={d},{d}\n", .{ d1, c1, c2 });
}
