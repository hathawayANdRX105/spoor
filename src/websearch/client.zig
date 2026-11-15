//! web_search：DuckDuckGo HTML 端点，无 API key。自建部分。

const std = @import("std");

/// 一条搜索结果。
pub const Result = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.snippet);
    }
};

/// 搜索 query，返回结果列表（title/url/snippet）。
/// 依赖外部网络；失败时调用方应降级为仅本地检索。
pub fn search(allocator: std.mem.Allocator, query: []const u8) ![]Result {
    const url = try std.fmt.allocPrint(allocator, "https://html.duckduckgo.com/html/?q={s}", .{query});
    defer allocator.free(url);

    const html = try fetch(allocator, url);
    defer allocator.free(html);

    return extractResults(allocator, html);
}

fn fetch(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    return try aw.toOwnedSlice();
}

/// 从 DuckDuckGo HTML 提取结果（<a class="result__a" href="URL">TITLE</a> + snippet）。
fn extractResults(allocator: std.mem.Allocator, html: []const u8) ![]Result {
    var results = std.ArrayList(Result).empty;
    defer results.deinit(allocator);

    var pos: usize = 0;
    const anchor = "result__a";
    const href = "href=\"";
    const title_open = "\">";
    const title_close = "</a>";

    while (std.mem.indexOfPos(u8, html, pos, anchor)) |a| {
        // href 在 anchor 之前若干字符，向后找最近的前一个 href="
        const before = html[0..a];
        const href_start = std.mem.lastIndexOf(u8, before, href) orelse break;
        const url_start = href_start + href.len;
        const url_end = std.mem.indexOfScalarPos(u8, html, url_start, '"') orelse break;

        const title_start_rel = std.mem.indexOfPos(u8, html, url_end, title_open) orelse break;
        const title_start = title_start_rel + title_open.len;
        const title_end = std.mem.indexOfPos(u8, html, title_start, title_close) orelse break;

        const u = try allocator.dupe(u8, html[url_start..url_end]);
        errdefer allocator.free(u);
        const t = try allocator.dupe(u8, html[title_start..title_end]);
        errdefer allocator.free(t);

        try results.append(allocator, .{
            .title = t,
            .url = u,
            .snippet = "",
        });

        pos = title_end;
        if (results.items.len >= 8) break;
    }

    return try results.toOwnedSlice(allocator);
}
