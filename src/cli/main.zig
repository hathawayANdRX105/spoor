const std = @import("std");
const spoor = @import("spoor");

pub fn main() !void {
    std.debug.print("spoor v{s}\n", .{spoor.version});
}
