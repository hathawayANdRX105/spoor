//! web_search：纯 HTTP + SearXNG JSON API（可配置 URL，默认本地 8888）。
//! 自带 connect/read 超时（Select race + receiveTimeout），不依赖 std.http.Client
//! （其 connect timeout 在 0.17 仍是 TODO，会挂起）。

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

/// 一条搜索结果。
pub const Result = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

pub const Error = error{ WriteFailed, 
    Timeout,
    ConnectFailed,
    HttpProtocolError,
    JsonError,
    SqliteError,
    OutOfMemory,
} || Io.Cancelable;

pub const Options = struct {
    /// SearXNG 实例根（http://host:port）。
    base_url: []const u8 = "http://127.0.0.1:8888",
    /// TCP 连接超时。
    connect_timeout_ms: i64 = 5000,
    /// 整体读超时。
    read_timeout_ms: i64 = 10_000,
};

/// 解析 "http://host[:port][/path]"（仅 http；TLS 超出原型范围）。
const BaseUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,

    fn parse(url: []const u8) Error!BaseUrl {
        const prefix = "http://";
        if (!std.mem.startsWith(u8, url, prefix)) return Error.HttpProtocolError;
        const rest = url[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const authority = if (slash) |s| rest[0..s] else rest;
        const path = if (slash) |s| rest[s..] else "/";
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
        if (colon) |c| {
            const port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return Error.HttpProtocolError;
            return .{ .host = authority[0..c], .port = port, .path = path };
        }
        return .{ .host = authority, .port = 80, .path = path };
    }
};

/// 对 query 跑 websearch，返回 SearXNG 的结果列表。
pub fn search(
    allocator: std.mem.Allocator,
    io: Io,
    options: Options,
    query: []const u8,
) Error![]Result {
    const base = try BaseUrl.parse(options.base_url);

    // URL 编码 query（原型：只处理空白与保留字的基本百分号编码）
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(allocator);
    try encodeQuery(allocator, &qbuf, query);

    const path = try std.fmt.allocPrint(allocator, "{s}?q={s}&format=json", .{ base.path, qbuf.items });
    defer allocator.free(path);

    const body = try fetch(allocator, io, options, base, path);
    defer allocator.free(body);

    return parseResults(allocator, body);
}

/// 手写 HTTP/1.1 GET：connect（Select race 超时）→ 写请求 → 读响应（deadline）。
fn fetch(
    allocator: std.mem.Allocator,
    io: Io,
    options: Options,
    base: BaseUrl,
    path: []const u8,
) Error![]u8 {
    const host = net.HostName.init(base.host) catch return Error.HttpProtocolError;

    // 1) connect：与 sleep race 实现超时（0.17 的 ConnectOptions.timeout 是 TODO）
    const ConnectRace = union(enum) {
        connected: Error!net.Stream,
        timeout: void,
    };
    var sel = Io.Select(ConnectRace).init(io, &.{});
    defer sel.cancelDiscard();

    const S = @TypeOf(sel);
    sel.async(S.Field.connected, connectAsync, .{ host, io, base.port });
    sel.async(S.Field.timeout, connectTimeoutAsync, .{ io, options.connect_timeout_ms });

    const outcome = switch (sel.await() catch return Error.ConnectFailed) {
        .connected => |r| r,
        .timeout => return Error.Timeout,
    };
    const stream = try outcome;
    defer stream.close(io);

    // 2) 发送 HTTP GET（Connection: close → 服务端关闭即 EOF，可读全量）
    {
        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.print(
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n" ++
                "Accept: application/json\r\nAccept-Encoding: identity\r\n\r\n",
            .{ path, base.host },
        );
        w.interface.flush() catch return Error.ConnectFailed;
    }

    // 3) 读响应：headers 到 \r\n\r\n，再读 body（deadline 限流）
    const read_deadline: Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = options.read_timeout_ms * std.time.ns_per_ms },
        .clock = .awake,
    } };


    // 读 header（最多 64KB）
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(allocator);
    var hbuf: [1]u8 = undefined;
    while (true) {
        const n = receiveWithTimeout(io, stream, &hbuf, read_deadline) catch |err| switch (err) {
            error.Timeout => return Error.Timeout,
            else => return Error.HttpProtocolError,
        };
        if (n == 0) return Error.HttpProtocolError;
        try headers.appendSlice(allocator, &hbuf);
        if (std.mem.endsWith(u8, headers.items, "\r\n\r\n")) break;
        if (headers.items.len > 64 * 1024) return Error.HttpProtocolError;
    }
    const header_text = headers.items;
    const status_ok = std.mem.startsWith(u8, header_text, "HTTP/1.1 200") or
        std.mem.startsWith(u8, header_text, "HTTP/1.0 200");
    if (!status_ok) return Error.HttpProtocolError;

    var content_len: ?usize = null;
    var lines = std.mem.splitSequence(u8, header_text, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " ");
            content_len = std.fmt.parseInt(usize, v, 10) catch null;
        }
    }

    // body：已读入 reader 缓冲的部分 + 继续读
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    if (content_len) |cl| {
        try body.ensureTotalCapacity(allocator, cl);
    }
    // 先把 reader 里已缓冲的 header 之后内容搬过来
    if (std.mem.indexOf(u8, header_text, "\r\n\r\n")) |sep| {
        const after = header_text[sep + 4 ..];
        if (content_len) |cl| {
            const take = @min(after.len, cl);
            try body.appendSlice(allocator, after[0..take]);
        } else {
            try body.appendSlice(allocator, after);
        }
    }
    while (content_len == null or body.items.len < content_len.?) {
        var bbuf: [16 * 1024]u8 = undefined;
        const n = receiveWithTimeout(io, stream, &bbuf, read_deadline) catch |err| switch (err) {
            error.Timeout => return Error.Timeout,
            else => break,
        };
        if (n == 0) break;
        try body.appendSlice(allocator, bbuf[0..n]);
        if (content_len) |cl| {
            if (body.items.len >= cl) break;
        }
    }
    return try body.toOwnedSlice(allocator);
}

fn receiveWithTimeout(io: Io, stream: net.Stream, buf: []u8, timeout: Io.Timeout) net.Socket.ReceiveTimeoutError!usize {
    const msg = try stream.socket.receiveTimeout(io, buf, timeout);
    return msg.data.len;
}

fn connectAsync(host: net.HostName, io: Io, port: u16) Error!net.Stream {
    return host.connect(io, port, .{ .mode = .stream }) catch return Error.ConnectFailed;
}

fn connectTimeoutAsync(io: Io, timeout_ms: i64) void {
    Io.sleep(io, .{ .nanoseconds = timeout_ms * std.time.ns_per_ms }, .awake) catch {};
}

/// 百分号编码（保守：非字母数字全部编码）。
fn encodeQuery(allocator: std.mem.Allocator, out: *std.ArrayList(u8), query: []const u8) Error!void {
    const hex = "0123456789ABCDEF";
    for (query) |b| {
        const keep = std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~';
        if (keep) {
            try out.append(allocator, b);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[b >> 4]);
            try out.append(allocator, hex[b & 0xF]);
        }
    }
}

/// 解析 SearXNG JSON：{"results": [{"title","url","content"}...]}。
fn parseResults(allocator: std.mem.Allocator, body: []const u8) Error![]Result {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return Error.JsonError;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.JsonError,
    };
    const results_val = root_obj.get("results") orelse return Error.JsonError;
    const arr = switch (results_val) {
        .array => |a| a,
        else => return Error.JsonError,
    };

    var out: std.ArrayList(Result) = .empty;
    errdefer {
        for (out.items) |r| {
            allocator.free(r.title);
            allocator.free(r.url);
            allocator.free(r.snippet);
        }
        out.deinit(allocator);
    }

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const title = try strField(allocator, obj, "title");
        errdefer allocator.free(title);
        const url = try strField(allocator, obj, "url");
        errdefer allocator.free(url);
        const content = try strField(allocator, obj, "content");
        errdefer allocator.free(content);
        try out.append(allocator, .{ .title = title, .url = url, .snippet = content });
    }
    return try out.toOwnedSlice(allocator);
}

fn strField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    const v = obj.get(name) orelse return "";
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    };
}
