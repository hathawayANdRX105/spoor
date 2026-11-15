//! 极简 SQLite 绑定：extern 声明 + 我们需要的 API 子集。
//! 替代 zig-sqlite（其 @cImport 在 Zig 0.17 被移除，库未适配）。
//! 接口与原 zig-sqlite 用法保持一致（execDynamic/oneDynamicAlloc/prepareDynamic）。

const std = @import("std");

// ---------------------------------------------------------------------------
// C API（extern 声明，sqlite3.c 由 build.zig 编译链接）
// ---------------------------------------------------------------------------

const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};

    pub const OK: c_int = 0;
    pub const ROW: c_int = 100;
    pub const DONE: c_int = 101;

    pub const OPEN_READWRITE: c_int = 0x2;
    pub const OPEN_CREATE: c_int = 0x4;
    pub const OPEN_URI: c_int = 0x40;

    pub const NULL: c_int = 5;

    pub const DESTRUCTOR_TRANSIENT: ?*const fn (?*anyopaque) callconv(.c) void =
        @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

    pub extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
    pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
    pub extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
    pub extern fn sqlite3_last_insert_rowid(db: *sqlite3) i64;
    pub extern fn sqlite3_changes(db: *sqlite3) c_int;
    pub extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, nbyte: c_int, stmt: *?*sqlite3_stmt, tail: ?*[*]const u8) c_int;
    pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, value: i64) c_int;
    pub extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, idx: c_int, value: f64) c_int;
    pub extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, idx: c_int) c_int;
    pub extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, idx: c_int, value: [*]const u8, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
    pub extern fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;
    pub extern fn sqlite3_column_type(stmt: *sqlite3_stmt, col: c_int) c_int;
    pub extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, col: c_int) i64;
    pub extern fn sqlite3_column_double(stmt: *sqlite3_stmt, col: c_int) f64;
    pub extern fn sqlite3_column_text(stmt: *sqlite3_stmt, col: c_int) ?[*:0]const u8;
    pub extern fn sqlite3_column_blob(stmt: *sqlite3_stmt, col: c_int) ?*const anyopaque;
    pub extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, col: c_int) c_int;
};

// ---------------------------------------------------------------------------
// 错误
// ---------------------------------------------------------------------------

pub const Error = error{ SqliteError, OutOfMemory };

fn lastError(db: *c.sqlite3) Error {
    const msg = c.sqlite3_errmsg(db);
    std.debug.print("sqlite error: {s}\n", .{msg});
    return Error.SqliteError;
}

fn check(db: *c.sqlite3, rc: c_int) Error!void {
    if (rc != c.OK) return lastError(db);
}

// ---------------------------------------------------------------------------
// Db
// ---------------------------------------------------------------------------

pub const Db = struct {
    handle: *c.sqlite3,

    pub const Mode = union(enum) {
        file: [:0]const u8,
        memory,
    };

    pub const InitOptions = struct {
        mode: Mode,
        open_flags: struct { write: bool = false, create: bool = false } = .{},
    };

    pub fn init(options: InitOptions) Error!Db {
        var flags: c_int = c.OPEN_URI;
        flags |= if (options.open_flags.write) c.OPEN_READWRITE else 0;
        flags |= if (options.open_flags.create) c.OPEN_CREATE else 0;

        var handle: ?*c.sqlite3 = null;
        const path: [*:0]const u8 = switch (options.mode) {
            .file => |p| p.ptr,
            .memory => ":memory:",
        };
        const rc = c.sqlite3_open_v2(path, &handle, flags, null);
        if (rc != c.OK) {
            if (handle) |h| {
                std.debug.print("sqlite open error: {s}\n", .{c.sqlite3_errmsg(h)});
                _ = c.sqlite3_close(h);
            }
            return Error.SqliteError;
        }
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
        self.handle = undefined;
    }

    pub fn getLastInsertRowID(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// 动态 SQL 执行（? 占位符 + 位置 tuple 绑定）。
    pub fn execDynamic(self: *Db, sql: []const u8, options: anytype, values: anytype) Error!void {
        _ = options;
        var stmt = try Statement.prepare(self, sql);
        defer stmt.deinit();
        try stmt.bindValues(values);
        _ = try stmt.stepToCompletion();
    }

    pub fn oneDynamicAlloc(self: *Db, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, options: anytype, values: anytype) Error!?T {
        _ = options;
        var stmt = try Statement.prepare(self, sql);
        defer stmt.deinit();
        try stmt.bindValues(values);
        const rc = c.sqlite3_step(stmt.handle);
        switch (rc) {
            c.ROW => return try parseRow(T, allocator, stmt.handle),
            c.DONE => return null,
            else => return lastError(self.handle),
        }
    }

    pub fn prepareDynamic(self: *Db, sql: []const u8) Error!Statement {
        return Statement.prepare(self, sql);
    }

    /// prepare + 逐行收集（等价原 zig-sqlite 的 all 用法）。
    pub fn allDynamicAlloc(self: *Db, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, options: anytype, values: anytype) Error![]T {
        _ = options;
        var stmt = try Statement.prepare(self, sql);
        defer stmt.deinit();
        try stmt.bindValues(values);
        return stmt.collectRows(T, allocator);
    }
};

// ---------------------------------------------------------------------------
// Statement
// ---------------------------------------------------------------------------

pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    db: *Db,

    pub fn prepare(db: *Db, sql: []const u8) Error!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.OK) return lastError(db.handle);
        return .{ .handle = stmt.?, .db = db };
    }

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.handle = undefined;
    }

    fn stepToCompletion(self: *Statement) Error!void {
        while (true) {
            const rc = c.sqlite3_step(self.handle);
            switch (rc) {
                c.ROW => {},
                c.DONE => return,
                else => return lastError(self.db.handle),
            }
        }
    }

    fn bindValues(self: *Statement, values: anytype) Error!void {
        const info = @typeInfo(@TypeOf(values)).@"struct";
        inline for (info.field_names, 0..) |f_name, i| {
            try bindValue(self.db.handle, self.handle, @intCast(i + 1), @field(values, f_name));
        }
    }

    /// 收集全部行为 T 数组（T 字段按列顺序）。
    pub fn collectRows(self: *Statement, comptime T: type, allocator: std.mem.Allocator) Error![]T {
        var list: std.ArrayList(T) = .empty;
        errdefer {
            for (list.items) |*row| freeRow(T, allocator, row);
            list.deinit(allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(self.handle);
            switch (rc) {
                c.ROW => try list.append(allocator, try parseRow(T, allocator, self.handle)),
                c.DONE => break,
                else => return lastError(self.db.handle),
            }
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn oneAlloc(self: *Statement, comptime T: type, allocator: std.mem.Allocator, options: anytype, values: anytype) Error!?T {
        _ = options;
        try self.bindValues(values);
        const rc = c.sqlite3_step(self.handle);
        switch (rc) {
            c.ROW => return try parseRow(T, allocator, self.handle),
            c.DONE => return null,
            else => return lastError(self.db.handle),
        }
    }

    pub fn all(self: *Statement, comptime T: type, allocator: std.mem.Allocator, options: anytype, values: anytype) Error![]T {
        _ = options;
        try self.bindValues(values);
        return self.collectRows(T, allocator);
    }
};

// ---------------------------------------------------------------------------
// 绑定与行解析（comptime 反射）
// ---------------------------------------------------------------------------

fn bindValue(db: *c.sqlite3, stmt: *c.sqlite3_stmt, idx: c_int, value: anytype) Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try check(db, c.sqlite3_bind_int64(stmt, idx, @intCast(value))),
        .float, .comptime_float => try check(db, c.sqlite3_bind_double(stmt, idx, @floatCast(value))),
        .bool => try check(db, c.sqlite3_bind_int64(stmt, idx, @intFromBool(value))),
        .null => try check(db, c.sqlite3_bind_null(stmt, idx)),
        .pointer => |p| switch (p.size) {
            .slice => switch (p.child) {
                u8 => try check(db, c.sqlite3_bind_text(stmt, idx, value.ptr, @intCast(value.len), c.DESTRUCTOR_TRANSIENT)),
                f32 => try check(db, c.sqlite3_bind_blob(stmt, idx, std.mem.sliceAsBytes(value).ptr, @intCast(value.len * 4), c.DESTRUCTOR_TRANSIENT)),
                else => @compileError("unsupported bind slice type " ++ @typeName(T)),
            },
            .one => @compileError("unsupported bind pointer " ++ @typeName(T)),
            else => @compileError("unsupported bind pointer " ++ @typeName(T)),
        },
        else => @compileError("unsupported bind type " ++ @typeName(T)),
    }
}

fn parseRow(comptime T: type, allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) Error!T {
    var row: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names, 0..) |f_name, i| {
        const col: c_int = @intCast(i);
        const is_null = c.sqlite3_column_type(stmt, col) == c.NULL;
        switch (@typeInfo(@TypeOf(@field(row, f_name)))) {
            .int => |it| {
                if (is_null) {
                    @field(row, f_name) = 0;
                } else {
                    const v = c.sqlite3_column_int64(stmt, col);
                    @field(row, f_name) = switch (it.signedness) {
                        .signed => @intCast(v),
                        .unsigned => @intCast(@max(0, v)),
                    };
                }
            },
            .float => @field(row, f_name) = if (is_null) 0 else @floatCast(c.sqlite3_column_double(stmt, col)),
            .bool => @field(row, f_name) = if (is_null) false else c.sqlite3_column_int64(stmt, col) != 0,
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    if (is_null) {
                        @field(row, f_name) = "";
                    } else {
                        const txt = c.sqlite3_column_text(stmt, col);
                        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
                        @field(row, f_name) = if (txt != null)
                            try allocator.dupe(u8, txt.?[0..len])
                        else
                            "";
                    }
                } else if (p.size == .slice and p.child == f32) {
                    if (is_null) {
                        @field(row, f_name) = &.{};
                    } else {
                        const blob = c.sqlite3_column_blob(stmt, col);
                        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
                        const bytes: []align(1) const u8 = @as([*]align(1) const u8, @ptrCast(blob.?))[0..len];
                        const dst = try allocator.alignedAlloc(f32, 4, len / 4);
                        @memcpy(dst, @as([]align(1) const f32, @ptrCast(bytes)));
                        @field(row, f_name) = dst;
                    }
                } else @compileError("unsupported row field " ++ @typeName(@TypeOf(@field(row, f_name))));
            },
            else => @compileError("unsupported row field " ++ @typeName(@TypeOf(@field(row, f_name)))),
        }
    }
    return row;
}

fn freeRow(comptime T: type, allocator: std.mem.Allocator, row: *T) void {
    inline for (@typeInfo(T).@"struct".field_names) |f_name| {
        switch (@typeInfo(@TypeOf(@field(row, f_name)))) {
            .pointer => |p| {
                if (p.size == .slice) allocator.free(@field(row, f_name));
            },
            else => {},
        }
    }
}
