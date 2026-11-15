//! judge：判定能力（rerank/find 的最小子集），jev 兼容 wire 协议。
//! 语义对齐 mnemo2u R4：≤250 候选、noul 0..1 校验、near-zero 整列 miss、
//! 失败/禁用降级（保留融合顺序）。

const std = @import("std");
const Io = std.Io;

pub const MAX_CANDIDATES: usize = 250;
pub const MAX_RERANK_TOTAL_CHARS: usize = 100_000;
pub const MAX_CANDIDATE_CHARS: usize = 2000;
pub const NEAR_ZERO: f64 = 0.05;

/// rerank 候选。
pub const Candidate = struct {
    id: []const u8,
    text: []const u8,
};

/// rerank 命中（relevance ∈ 0..1）。
pub const Hit = struct {
    id: []const u8,
    relevance: f64,
};

pub const Error = error{ SystemFdQuotaExceeded,  SocketUnconnected,  ProcessFdQuotaExceeded,  PortUnreachable,  NetworkDown,  MessageOversize,  ConnectionTimedOut,  ConnectionResetByPeer,  ConcurrencyUnavailable,  Unexpected,  SystemResources,  Timeout,  NoSpaceLeft,  WriteFailed, 
    Disabled,
    Backend,
    InvalidResponse,
} || std.mem.Allocator.Error || Io.Cancelable;

/// 判定配置。
pub const Config = struct {
    /// jev 兼容判定端点 URL（http）。空 = disabled（零网络）。
    endpoint: []const u8 = "",
    model: []const u8 = "spoor-judge",
    api_key: []const u8 = "",
    connect_timeout_ms: i64 = 5000,
    read_timeout_ms: i64 = 20_000,
};

/// judge 是否启用（endpoint 非空）。
pub fn isEnabled(config: Config) bool {
    return config.endpoint.len > 0;
}

/// rerank：对 query 与 candidates 发 jev noul 判定，返回按 relevance 降序的 hits。
/// 失败 → Error.Backend（调用方降级：保留融合顺序）。
pub fn rerank(
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    query: []const u8,
    candidates: []const Candidate,
) Error![]Hit {
    if (!isEnabled(config)) return Error.Disabled;
    if (candidates.len == 0) return &.{};
    if (candidates.len > MAX_CANDIDATES) return Error.InvalidResponse;

    var total_chars: usize = 0;
    for (candidates) |cand| total_chars += cand.text.len;
    if (total_chars > MAX_RERANK_TOTAL_CHARS) return Error.InvalidResponse;

    // 组 jev 请求体
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();

    try w.writer.print("{{\"model\":\"{s}\",\"state\":{{\"query\":", .{config.model});
    try jsonEscape(&w.writer, query);
    try w.writer.writeAll("},\"questions\":{");

    for (candidates, 0..) |cand, i| {
        if (i != 0) try w.writer.writeAll(",");
        try w.writer.print("\"rel_{d}\":{{\"type\":\"noul\",\"instructions\":", .{i});
        try jsonEscape(&w.writer, cand.text[0..@min(cand.text.len, MAX_CANDIDATE_CHARS)]);
        try w.writer.writeAll(",\"criteria\":{\"true\":\"The candidate addresses the subject the query asks about, or provides what it seeks\",\"false\":\"The candidate is about a different subject, or only shares vocabulary with the query\"}}");
    }
    try w.writer.writeAll("}}");

    // HTTP POST
    const body_json = try w.toOwnedSlice();
    defer allocator.free(body_json);
    const response_body = try post(allocator, io, config, body_json);
    defer allocator.free(response_body);

    // 解析 answers
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch
        return Error.InvalidResponse;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.InvalidResponse,
    };
    const answers = root_obj.get("answers") orelse return Error.InvalidResponse;
    const answers_obj = switch (answers) {
        .object => |o| o,
        else => return Error.InvalidResponse,
    };

    var hits = std.ArrayList(Hit).empty;
    errdefer {
        hits.deinit(allocator);
    }

    for (candidates, 0..) |cand, i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "rel_{d}", .{i});
        const answer = answers_obj.get(key) orelse return Error.InvalidResponse;
        const noul = switch (answer) {
            .object => |o| blk: {
                const n = o.get("noul") orelse return Error.InvalidResponse;
                break :blk switch (n) {
                    .float => |f| f,
                    .integer => |x| @as(f64, @floatFromInt(x)),
                    else => return Error.InvalidResponse,
                };
            },
            else => return Error.InvalidResponse,
        };
        if (!std.math.isFinite(noul) or noul < 0.0 or noul > 1.0) return Error.InvalidResponse;
        const hit_id = try allocator.dupe(u8, cand.id);
        errdefer allocator.free(hit_id);
        try hits.append(allocator, .{ .id = hit_id, .relevance = noul });
    }

    // relevance 降序
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lessThan(_: void, a: Hit, b: Hit) bool {
            return a.relevance > b.relevance;
        }
    }.lessThan);

    return try hits.toOwnedSlice(allocator);
}

/// near-zero 整列 miss 判定（mnemo2u R4 语义）。
pub fn isNearZeroMiss(hits: []const Hit) bool {
    if (hits.len == 0) return false;
    for (hits) |h| {
        if (h.relevance > NEAR_ZERO) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// HTTP POST（手写 HTTP/1.1 + Select race 超时，同 websearch）
// ---------------------------------------------------------------------------

fn post(allocator: std.mem.Allocator, io: Io, config: Config, body_json: []const u8) Error![]u8 {
    // 解析 endpoint：http://host:port/path
    const prefix = "http://";
    if (!std.mem.startsWith(u8, config.endpoint, prefix)) return Error.Backend;
    const rest = config.endpoint[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return Error.Backend;
    const authority = rest[0..slash];
    const path = rest[slash..];

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    var host_str = authority;
    var port: u16 = 80;
    if (colon) |c| {
        host_str = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return Error.Backend;
    }

    const host = net.HostName.init(host_str) catch return Error.Backend;

    // connect：Select race 超时
    const ConnectRace = union(enum) { connected: Error!net.Stream, timeout: void };
    var sel = Io.Select(ConnectRace).init(io, &.{});
    defer sel.cancelDiscard();
    const S = @TypeOf(sel);
    sel.async(S.Field.connected, connectAsync, .{ host, io, port });
    sel.async(S.Field.timeout, connectTimeoutAsync, .{ io, config.connect_timeout_ms });
    const stream = switch (sel.await() catch return Error.Backend) {
        .connected => |r| r catch return Error.Backend,
        .timeout => return Error.Backend,
    };
    defer stream.close(io);

    // 发送 POST
    {
        var wbuf: [8192]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        w.interface.print(
            "POST {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n" ++
                "Content-Type: application/json\r\nContent-Length: {d}\r\n" ++
                "Authorization: Bearer {s}\r\n\r\n",
            .{ path, host_str, body_json.len, config.api_key },
        ) catch return Error.Backend;
        w.interface.writeAll(body_json) catch return Error.Backend;
        w.interface.flush() catch return Error.Backend;
    }

    // 读响应（headers 到 \r\n\r\n + Content-Length body）
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(allocator);
    var hbuf: [1]u8 = undefined;
    while (true) {
        const n = try readWithTimeout(io, stream, &hbuf, config.read_timeout_ms);
        if (n == 0) return Error.Backend;
        try headers.appendSlice(allocator, hbuf[0..n]);
        if (std.mem.endsWith(u8, headers.items, "\r\n\r\n")) break;
        if (headers.items.len > 64 * 1024) return Error.Backend;
    }

    if (!std.mem.startsWith(u8, headers.items, "HTTP/1.1 200") and
        !std.mem.startsWith(u8, headers.items, "HTTP/1.0 200"))
    {
        return Error.Backend;
    }

    var content_len: ?usize = null;
    var lines = std.mem.splitSequence(u8, headers.items, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " ");
            content_len = std.fmt.parseInt(usize, v, 10) catch null;
        }
    }

    var body_out: std.ArrayList(u8) = .empty;
    errdefer body_out.deinit(allocator);
    if (std.mem.indexOf(u8, headers.items, "\r\n\r\n")) |sep| {
        const after = headers.items[sep + 4 ..];
        try body_out.appendSlice(allocator, after);
    }
    while (content_len == null or body_out.items.len < content_len.?) {
        var bbuf: [16 * 1024]u8 = undefined;
        const n = try readWithTimeout(io, stream, &bbuf, config.read_timeout_ms);
        if (n == 0) break;
        try body_out.appendSlice(allocator, bbuf[0..n]);
        if (content_len) |cl| {
            if (body_out.items.len >= cl) break;
        }
    }
    return try body_out.toOwnedSlice(allocator);
}

fn readWithTimeout(
    io: Io,
    stream: net.Stream,
    buf: []u8,
    timeout_ms: i64,
) !usize {
    const msg = try stream.socket.receiveTimeout(
        io,
        buf,
        .{ .duration = .{ .raw = .{ .nanoseconds = timeout_ms * std.time.ns_per_ms }, .clock = .awake } },
    );
    return msg.data.len;
}

fn connectAsync(host: net.HostName, io: Io, port: u16) net.Stream {
    return host.connect(io, port, .{ .mode = .stream }) catch unreachable;
}

fn connectTimeoutAsync(io: Io, timeout_ms: i64) void {
    Io.sleep(io, .{ .nanoseconds = timeout_ms * std.time.ns_per_ms }, .awake) catch {};
}

fn jsonEscape(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (b < 0x20) {
                    try w.print("\\u{x:0>4}", .{b});
                } else {
                    try w.writeByte(b);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------
// Mock（测试用）：确定性 noul——query 与 candidate 文本的重叠词比例
// ---------------------------------------------------------------------------

pub const Mock = struct {
    pub fn rerank(
        allocator: std.mem.Allocator,
        config: Config,
        query: []const u8,
        candidates: []const Candidate,
    ) ![]Hit {
        _ = config;
        var hits = std.ArrayList(Hit).empty;
        errdefer hits.deinit(allocator);

        for (candidates, 0..) |cand, i| {
            const rel = mockRelevance(query, cand.text);
            const hit_id = try allocator.dupe(u8, cand.id);
            errdefer allocator.free(hit_id);
            try hits.append(allocator, .{ .id = hit_id, .relevance = rel });
            _ = i;
        }
        std.mem.sort(Hit, hits.items, {}, struct {
            fn lessThan(_: void, a: Hit, b: Hit) bool {
                return a.relevance > b.relevance;
            }
        }.lessThan);
        return try hits.toOwnedSlice(allocator);
    }

    fn mockRelevance(query: []const u8, text: []const u8) f64 {
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(std.heap.page_allocator);
        var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:!?()");
        while (it.next()) |word| words.append(std.heap.page_allocator, word) catch return 0;

        if (words.items.len == 0) return 0;
        var matched: usize = 0;
        for (words.items) |word| {
            if (std.mem.indexOf(u8, text, word) != null) matched += 1;
        }
        return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(words.items.len));
    }
};

const net = std.Io.net;

test {
    _ = @import("judge_test.zig");
}
