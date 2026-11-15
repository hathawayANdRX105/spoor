//! RRF（Reciprocal Rank Fusion）多臂融合 + 稳定 tie-break。

const std = @import("std");

/// RRF 融合：score(id) = Σ 1/(k + rank)。
/// 返回按融合分降序的 id 列表；同分按 id 升序（稳定 tie-break）。
pub fn reciprocalRankFusion(allocator: std.mem.Allocator, ranked_lists: []const []const u64, k: u64) ![]u64 {
    var scores = std.AutoHashMap(u64, f64).init(allocator);
    defer scores.deinit();

    for (ranked_lists) |list| {
        for (list, 0..) |id, rank| {
            const contribution = 1.0 / @as(f64, @floatFromInt(k + rank + 1));
            const entry = try scores.getOrPut(id);
            if (entry.found_existing) {
                entry.value_ptr.* += contribution;
            } else {
                entry.value_ptr.* = contribution;
            }
        }
    }

    var result = try allocator.alloc(u64, scores.count());
    var it = scores.keyIterator();
    var i: usize = 0;
    while (it.next()) |id| : (i += 1) {
        result[i] = id.*;
    }

    std.mem.sort(u64, result, scores, struct {
        fn lessThan(ctx: std.AutoHashMap(u64, f64), a: u64, b: u64) bool {
            const sa = ctx.get(a) orelse 0.0;
            const sb = ctx.get(b) orelse 0.0;
            if (sa != sb) return sa > sb;
            return a < b;
        }
    }.lessThan);
    return result;
}

test {
    _ = @import("fusion_test.zig");
}
