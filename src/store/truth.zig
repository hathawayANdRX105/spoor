//! 真值模型：唯一 commit point。
//! 文档 / 块 / 事实都写在这里；所有派生索引从这里重建。

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
