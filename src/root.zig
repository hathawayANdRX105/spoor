//! spoor — 简化 RAG 与调查任务 harness 的库入口（facade）。
//!
//! 分层（单向依赖）：
//!   cli → harness → retrieve → store
//!              ↳ websearch ↗
//!
//! store/ 是唯一 commit point（SQLite 真值 + 派生索引），
//! retrieve/ 做多臂检索与融合，harness/ 编排调查，eval/ 评测。

pub const version = "0.1.0";

pub const store = @import("store/store.zig");
pub const retrieve = @import("retrieve/retrieve.zig");
pub const websearch = @import("websearch/websearch.zig");
pub const harness = @import("harness/harness.zig");
pub const eval = @import("eval/eval.zig");
pub const judge_mod = @import("judge/mod.zig");

test "facade re-exports every layer" {
    _ = store;
    _ = retrieve;
    _ = websearch;
    _ = harness;
    _ = eval;
    _ = judge_mod;
}
