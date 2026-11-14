//! 评测层：judge 能力 + 评测用例。

pub const judge = @import("judge.zig");
pub const cases = @import("cases.zig");

test {
    _ = judge;
    _ = cases;
}
