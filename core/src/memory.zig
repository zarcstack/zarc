//! Allocator infrastructure. Every allocation in zarc goes through a
//! ZarcAllocator. No global malloc, no hidden allocators.

const std = @import("std");

pub const Allocator = extern struct {
    alloc_fn: *const fn (ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    realloc_fn: *const fn (ctx: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    free_fn: *const fn (ctx: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void,
    ctx: ?*anyopaque,

    pub fn alloc(self: *const Allocator, size: usize, alignment: usize) ?[*]u8 {
        const raw = self.alloc_fn(self.ctx, size, alignment) orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    pub fn realloc(
        self: *const Allocator,
        ptr: ?[*]u8,
        old_size: usize,
        new_size: usize,
        alignment: usize,
    ) ?[*]u8 {
        const raw: ?*anyopaque = if (ptr) |p| @ptrCast(p) else null;
        const result = self.realloc_fn(self.ctx, raw, old_size, new_size, alignment) orelse return null;
        return @ptrCast(@alignCast(result));
    }

    pub fn free(self: *const Allocator, ptr: ?[*]u8, size: usize, alignment: usize) void {
        const raw: ?*anyopaque = if (ptr) |p| @ptrCast(p) else null;
        self.free_fn(self.ctx, raw, size, alignment);
    }

    pub fn toStd(self: *const Allocator) std.mem.Allocator {
        return .{
            .ptr = @constCast(self),
            .vtable = &c_vtable,
        };
    }
};

const c_vtable: std.mem.Allocator.VTable = .{
    .alloc = cAlloc,
    .resize = cResize,
    .remap = cRemap,
    .free = cFree,
};

fn cAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *const Allocator = @ptrCast(@alignCast(ctx));
    return self.alloc(len, alignment.toByteUnits());
}

fn cResize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn cRemap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    _ = ret_addr;
    const self: *const Allocator = @ptrCast(@alignCast(ctx));
    return self.realloc(memory.ptr, memory.len, new_len, alignment.toByteUnits());
}

fn cFree(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    _ = ret_addr;
    const self: *const Allocator = @ptrCast(@alignCast(ctx));
    self.free(memory.ptr, memory.len, alignment.toByteUnits());
}

pub fn fromStd(zig_alloc: *const std.mem.Allocator) Allocator {
    return .{
        .alloc_fn = stdAllocShim,
        .realloc_fn = stdReallocShim,
        .free_fn = stdFreeShim,
        .ctx = @ptrCast(@constCast(zig_alloc)),
    };
}

fn stdAllocShim(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx orelse return null));
    const a = std.mem.Alignment.fromByteUnits(alignment);
    const buf = zig_alloc.rawAlloc(size, a, @returnAddress()) orelse return null;
    return @ptrCast(buf);
}

fn stdReallocShim(
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    old_size: usize,
    new_size: usize,
    alignment: usize,
) callconv(.c) ?*anyopaque {
    const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx orelse return null));
    const a = std.mem.Alignment.fromByteUnits(alignment);

    const new_buf = zig_alloc.rawAlloc(new_size, a, @returnAddress()) orelse return null;
    if (ptr) |p| {
        const copy_size = @min(old_size, new_size);
        @memcpy(new_buf[0..copy_size], @as([*]const u8, @ptrCast(p))[0..copy_size]);
        const old_slice = @as([*]u8, @ptrCast(p))[0..old_size];
        zig_alloc.rawFree(old_slice, a, @returnAddress());
    }
    return @ptrCast(new_buf);
}

fn stdFreeShim(
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    size: usize,
    alignment: usize,
) callconv(.c) void {
    const p = ptr orelse return;
    const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx orelse return));
    const a = std.mem.Alignment.fromByteUnits(alignment);
    const slice = @as([*]u8, @ptrCast(p))[0..size];
    zig_alloc.rawFree(slice, a, @returnAddress());
}

const system_base = std.heap.page_allocator;

pub fn system() Allocator {
    return .{
        .alloc_fn = systemAlloc,
        .realloc_fn = systemRealloc,
        .free_fn = systemFree,
        .ctx = null,
    };
}

fn systemAlloc(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    _ = ctx;
    const a = std.mem.Alignment.fromByteUnits(alignment);
    const buf = system_base.rawAlloc(size, a, @returnAddress()) orelse return null;
    return @ptrCast(buf);
}

fn systemRealloc(
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    old_size: usize,
    new_size: usize,
    alignment: usize,
) callconv(.c) ?*anyopaque {
    _ = ctx;
    const a = std.mem.Alignment.fromByteUnits(alignment);

    const new_buf = system_base.rawAlloc(new_size, a, @returnAddress()) orelse return null;
    if (ptr) |p| {
        const copy_size = @min(old_size, new_size);
        @memcpy(new_buf[0..copy_size], @as([*]const u8, @ptrCast(p))[0..copy_size]);
        const old_slice = @as([*]u8, @ptrCast(p))[0..old_size];
        system_base.rawFree(old_slice, a, @returnAddress());
    }
    return @ptrCast(new_buf);
}

fn systemFree(
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    size: usize,
    alignment: usize,
) callconv(.c) void {
    _ = ctx;
    const p = ptr orelse return;
    const a = std.mem.Alignment.fromByteUnits(alignment);
    const slice = @as([*]u8, @ptrCast(p))[0..size];
    system_base.rawFree(slice, a, @returnAddress());
}

// Tests.

test "system: alloc and free" {
    const a = system();
    const ptr = a.alloc(128, 8) orelse return error.OutOfMemory;
    defer a.free(ptr, 128, 8);

    @memset(ptr[0..128], 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), ptr[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), ptr[127]);
}

test "system: high alignment" {
    const a = system();
    const ptr = a.alloc(64, 64) orelse return error.OutOfMemory;
    defer a.free(ptr, 64, 64);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % 64);
}

test "system: realloc preserves content" {
    const a = system();
    const p1 = a.alloc(16, 8) orelse return error.OutOfMemory;
    @memset(p1[0..16], 0xCD);

    const p2 = a.realloc(p1, 16, 32, 8) orelse {
        a.free(p1, 16, 8);
        return error.OutOfMemory;
    };
    defer a.free(p2, 32, 8);

    try std.testing.expectEqual(@as(u8, 0xCD), p2[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), p2[15]);
}

test "toStd: bridge to std.mem.Allocator" {
    const a = system();
    const std_a = a.toStd();

    const buf = try std_a.alloc(u8, 256);
    defer std_a.free(buf);

    @memset(buf, 0xEF);
    try std.testing.expectEqual(@as(u8, 0xEF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xEF), buf[255]);
}

test "fromStd: bridge from std.mem.Allocator" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const std_a = gpa.allocator();

    const a = fromStd(&std_a);

    const ptr = a.alloc(128, 8) orelse return error.OutOfMemory;
    defer a.free(ptr, 128, 8);

    @memset(ptr[0..128], 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), ptr[0]);
}
