//! 真值模型：唯一 commit point。
//! 文档 / 块 / 事实都写在这里；所有派生索引从这里重建。
const std = @import("std");
const zsql = @import("sqlite");

pub const Document = struct {
    id: u64,
    title: []const u8,
};

pub const Chunk = struct {
    id: u64,
    document_id: u64,
    text: []const u8,
};

pub const Fact = struct {
    id: u64,
    subject: []const u8,
    relation: []const u8,
    object: []const u8,
};

/// 打开（不存在则创建）位于 `path` 的真值数据库并完成 schema 迁移。
pub fn openDatabase(path: []const u8) !zsql.Db {
    const db = try zsql.Db.init(.{
        .mode = .{ .File = path },
        .open_flags = .{ .write = true, .create = true },
    });
    try db.exec(comptime "CREATE TABLE IF NOT EXISTS documents (id INTEGER PRIMARY KEY, title TEXT NOT NULL);", .{});
    try db.exec(comptime "CREATE TABLE IF NOT EXISTS chunks (id INTEGER PRIMARY KEY, document_id INTEGER NOT NULL, text TEXT NOT NULL);", .{});
    try db.exec(comptime "CREATE TABLE IF NOT EXISTS facts (id INTEGER PRIMARY KEY, subject TEXT NOT NULL, relation TEXT NOT NULL, object TEXT NOT NULL);", .{});
    return db;
}

/// 写入文档，返回新行的 id。
pub fn insertDocument(db: *zsql.Db, title: []const u8) !u64 {
    try db.exec(comptime "INSERT INTO documents (title) VALUES (:title)", .{ .title = title });
    return @intCast(db.getLastInsertRowID());
}

/// 写入文档块，返回新行的 id。
pub fn insertChunk(db: *zsql.Db, document_id: u64, text: []const u8) !u64 {
    try db.exec(comptime "INSERT INTO chunks (document_id, text) VALUES (:document_id, :text)", .{
        .document_id = document_id,
        .text = text,
    });
    return @intCast(db.getLastInsertRowID());
}

/// 写入事实，返回新行的 id。
pub fn insertFact(db: *zsql.Db, subject: []const u8, relation: []const u8, object: []const u8) !u64 {
    try db.exec(comptime "INSERT INTO facts (subject, relation, object) VALUES (:subject, :relation, :object)", .{
        .subject = subject,
        .relation = relation,
        .object = object,
    });
    return @intCast(db.getLastInsertRowID());
}

/// 按 id 查文档，未找到返回 null。
pub fn selectDocument(db: *zsql.Db, allocator: std.mem.Allocator, id: u64) !?Document {
    return try db.oneAlloc(Document, allocator, comptime "SELECT id, title FROM documents WHERE id = :id", .{ .id = id });
}

/// 按 document_id 查该文档的全部块，按 id 升序。
pub fn selectChunksByDocument(db: *zsql.Db, document_id: u64, allocator: std.mem.Allocator) ![]Chunk {
    return try db.all(Chunk, allocator, comptime "SELECT id, document_id, text FROM chunks WHERE document_id = :document_id ORDER BY id", .{ .document_id = document_id });
}

test "insert and select document/chunk/fact" {
    const allocator = std.testing.allocator;
    var db = try openDatabase(":memory:");
    defer db.deinit();

    const doc_id = try insertDocument(&db, allocator, "title-1");
    try insertChunk(&db, allocator, doc_id, "chunk text a");
    try insertChunk(&db, allocator, doc_id, "chunk text b");
    const fact_id = try insertFact(&db, allocator, "subject-1", "relation-1", "object-1");
    std.testing.expect(fact_id > 0);

    const doc = try selectDocument(&db, allocator, doc_id);
    if (doc) |d| {
        std.testing.expect(d.id == doc_id);
        std.testing.expect(std.mem.eql(u8, d.title, "title-1"));
    } else {
        std.testing.fail("expected document");
    }

    const doc_missing = try selectDocument(&db, allocator, 999999);
    std.testing.expect(doc_missing == null);

    const chunks = try selectChunksByDocument(&db, allocator, doc_id);
    defer allocator.free(chunks);
    std.testing.expectEqual(2, chunks.len);
    std.testing.expect(chunks[0].id < chunks[1].id);
    std.testing.expect(std.mem.eql(u8, chunks[0].text, "chunk text a"));
    std.testing.expect(std.mem.eql(u8, chunks[1].text, "chunk text b"));
    for (chunks) |c| {
        std.testing.expect(c.document_id == doc_id);
    }
}
