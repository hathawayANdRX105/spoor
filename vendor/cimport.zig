const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("workaround.h");
});
pub fn main() void { _ = c; }
