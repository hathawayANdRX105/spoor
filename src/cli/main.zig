const std = @import("std");
const spoor = @import("spoor");

pub fn main(init: std.process.Init) !void {
    // init.gpa 已带泄漏检查（debug）；init.arena 是进程级 arena。
    const allocator = init.gpa;

    var stdout_buf: [4096]u8 = undefined;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        var out_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
        try out_w.interface.print(
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
        try seed(&db, init.io);
        return;
    }

    const path = args[1];
    const question = if (args.len > 2) args[2] else "";

    var db = try spoor.store.openDatabase(allocator, path);
    defer db.deinit();

    if (question.len == 0) {
        var out_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
        try out_w.interface.print("spoor: opened {s}（无问题，退出）\n", .{path});
        return;
    }

    try spoor.harness.agent.investigate(&db, question, allocator, init.io, init.environ_map);
}

fn seed(db: *spoor.store.Database, io: std.Io) !void {
    const t = spoor.store.truth;
    const g = spoor.store.graph;

    const d1 = try t.insertDocument(db, "rag-intro");
    const c1 = try t.insertChunk(db, d1, "retrieval augmented generation combines search with language models");
    const c2 = try t.insertChunk(db, d1, "vector search uses embeddings to find similar text");

    // 图：c1 -> c2 通过 links 边（演示图扩展）
    _ = try g.insertNode(db, "chunk");
    _ = try g.insertEdge(db, c1, c2, "links");

    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    try stdout.interface.print("已写入演示数据：doc={d} chunks={d},{d}\n", .{ d1, c1, c2 });
}
