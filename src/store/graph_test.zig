//! graph（从主文件拆出）。

const std = @import("std");
const impl = @import("graph.zig");

test "insert nodes/edges, neighbors, and recursive walk" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try impl.migrate(&db);

    const a = try impl.insertNode(&db, "A");
    const b = try impl.insertNode(&db, "B");
    const c = try impl.insertNode(&db, "C");
    try impl.insertEdge(&db, a, b, "links");
    try impl.insertEdge(&db, b, c, "links");

    // 一跳邻居：A -> {B}
    const first = try impl.neighbors(&db, a, "links", allocator);
    defer allocator.free(first);
    try std.testing.expectEqual(1, first.len);
    try std.testing.expect(first[0] == b);

    // 不匹配的边类型：空
    const none = try impl.neighbors(&db, a, "replies", allocator);
    defer allocator.free(none);
    try std.testing.expectEqual(0, none.len);

    // 2-hop 遍历：A(0), B(1), C(2)
    const walked = try impl.walk(&db, a, 2, "links", allocator);
    defer allocator.free(walked);
    try std.testing.expectEqual(3, walked.len);

    var found_a: bool = false;
    var found_b: bool = false;
    var found_c: bool = false;
    for (walked) |w| {
        if (w.id == a and w.depth == 0) found_a = true;
        if (w.id == b and w.depth == 1) found_b = true;
        if (w.id == c and w.depth == 2) found_c = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
    try std.testing.expect(found_c);

    // 1-hop 只到 B
    const shallow = try impl.walk(&db, a, 1, "links", allocator);
    defer allocator.free(shallow);
    try std.testing.expectEqual(2, shallow.len);

    // 不存在的起点：只有起点自身，depth 0
    const lone = try impl.walk(&db, 9999, 3, "links", allocator);
    defer allocator.free(lone);
    try std.testing.expectEqual(1, lone.len);
    try std.testing.expect(lone[0].id == 9999 and lone[0].depth == 0);
}
