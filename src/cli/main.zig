const std = @import("std");
const spoor = @import("spoor");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const path: []const u8 = if (args.len > 1) args[1] else "spoor.db";
    var db = try spoor.store.openDatabase(allocator, path);
    defer db.deinit();
    std.debug.print("spoor: opened truth database at {s}\n", .{path});
}
