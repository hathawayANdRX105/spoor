//! timeseries（从主文件拆出）。

const std = @import("std");
const impl = @import("timeseries.zig");

test "append and range query" {
    const allocator = std.testing.allocator;
    var db = try @import("sqlite.zig").open(allocator, ":memory:");
    defer db.deinit();
    try impl.migrate(&db);

    _ = try impl.append(&db, 100, "ingest", "doc-1");
    _ = try impl.append(&db, 200, "ingest", "doc-2");
    _ = try impl.append(&db, 300, "recall", "query-1");

    const evs = try impl.range(&db, 150, 350, allocator);
    defer {
        for (evs) |e| {
            allocator.free(e.kind);
            allocator.free(e.payload);
        }
        allocator.free(evs);
    }
    try std.testing.expectEqual(2, evs.len);
    try std.testing.expect(evs[0].timestamp == 200);
    try std.testing.expect(evs[1].timestamp == 300);
}
