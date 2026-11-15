//! vector（从主文件拆出）。

const std = @import("std");
const impl = @import("vector.zig");

test "flat cosine search" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try impl.migrate(&db);

    try impl.insertVector(&db, 1, &[_]f32{ 1, 0, 0 });
    try impl.insertVector(&db, 2, &[_]f32{ 0, 1, 0 });
    try impl.insertVector(&db, 3, &[_]f32{ 1, 1, 0 });

    const top = try impl.search(&db, &[_]f32{ 1, 0, 0 }, 2, allocator);
    defer allocator.free(top);
    try std.testing.expectEqual(2, top.len);
    try std.testing.expect(top[0].chunk_id == 1);
    try std.testing.expect(top[0].score > top[1].score);
}
