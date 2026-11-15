//! 真值模型：唯一 commit point。
//! 文档 / 块 / 事实都写在这里；所有派生索引从这里重建。

const std = @import("std");
const Database = @import("sqlite.zig").Database;

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

/// 建立真值层 schema（幂等建表）。
pub fn migrate(db: *Database) !void {
    try db.execDynamic("CREATE TABLE IF NOT EXISTS documents (id INTEGER PRIMARY KEY, title TEXT NOT NULL);", .{}, .{});
    try db.execDynamic("CREATE TABLE IF NOT EXISTS chunks (id INTEGER PRIMARY KEY, document_id INTEGER NOT NULL, text TEXT NOT NULL);", .{}, .{});
    try db.execDynamic("CREATE TABLE IF NOT EXISTS facts (id INTEGER PRIMARY KEY, subject TEXT NOT NULL, relation TEXT NOT NULL, object TEXT NOT NULL);", .{}, .{});
}

/// 写入文档，返回新行的 id。
pub fn insertDocument(db: *Database, title: []const u8) !u64 {
    try db.execDynamic("INSERT INTO documents (title) VALUES (?)", .{}, .{title});
    return @intCast(db.getLastInsertRowID());
}

/// 写入文档块，返回新行的 id。
pub fn insertChunk(db: *Database, document_id: u64, text: []const u8) !u64 {
    try db.execDynamic("INSERT INTO chunks (document_id, text) VALUES (?, ?)", .{}, .{ document_id, text });
    return @intCast(db.getLastInsertRowID());
}

/// 写入事实，返回新行的 id。
pub fn insertFact(db: *Database, subject: []const u8, relation: []const u8, object: []const u8) !u64 {
    try db.execDynamic("INSERT INTO facts (subject, relation, object) VALUES (?, ?, ?)", .{}, .{ subject, relation, object });
    return @intCast(db.getLastInsertRowID());
}

/// 按 id 查文档，未找到返回 null。
pub fn selectDocument(db: *Database, allocator: std.mem.Allocator, id: u64) !?Document {
    return try db.oneDynamicAlloc(Document, allocator, "SELECT id, title FROM documents WHERE id = ?", .{}, .{id});
}

/// 按 id 查单个 chunk，未找到返回 null。
pub fn selectChunk(db: *Database, allocator: std.mem.Allocator, id: u64) !?Chunk {
    return try db.oneDynamicAlloc(Chunk, allocator, "SELECT id, document_id, text FROM chunks WHERE id = ?", .{}, .{id});
}

/// 按 document_id 查该文档的全部块，按 id 升序。
pub fn selectChunksByDocument(db: *Database, document_id: u64, allocator: std.mem.Allocator) ![]Chunk {
    var stmt = try db.prepareDynamic("SELECT id, document_id, text FROM chunks WHERE document_id = ? ORDER BY id");
    defer stmt.deinit();
    return try stmt.all(Chunk, allocator, .{}, .{document_id});
}

test {
    _ = @import("truth_test.zig");
}
