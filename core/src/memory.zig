//! Allocator infrastructure. Every allocation in zarc goes through a
//! ZarcAllocator. No global malloc, no hidden allocators.

const std = @import("std");
const c = std.c;

// C ABI struct. Layout matches zarc_allocator in include/zarc/allocator.h.
pub const Allocator = extern struct {
    alloc_fn: *const fn (ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.C) ?*anyopaque,
    realloc_fn: *const fn (ctx: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.C) ?*anyopaque,
    free_fn: *const fn (ctx: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.C) void,
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

    // View as Zig std.mem.Allocator. Borrows self; caller must keep self alive.
    pub fn toStd(self: *const Allocator) std.mem.Allocator {
        return .{
            .ptr = @constCast(self),
            .vtable = &c_vtable,
        };
    }
};

// std.mem.Allocator vtable shims. We cannot guarantee in-place resize, so
// resize returns false and remap attempts realloc.
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

// Wrap a Zig std.mem.Allocator as a C ABI allocator. Input pointer must
// outlive the returned Allocator.
pub fn fromStd(zig_alloc: *const std.mem.Allocator) Allocator {
    return .{
        .alloc_fn = stdAllocShim,
        .realloc_fn = stdReallocShim,
        .free_fn = stdFreeShim,
        .ctx = @ptrCast(@constCast(zig_alloc)),
    };
}

fn stdAllocShim(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.C) ?*anyopaque {
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
) callconv(.C) ?*anyopaque {
    const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx orelse return null));
    const a = std.mem.Alignment.fromByteUnits(alignment);

    if (ptr) |p| {
        const old_slice = @as([*]u8, @ptrCast(p))[0..old_size];
        if (zig_alloc.resize(old_slice, a, new_size, @returnAddress())) {
            return p;
        }
    }

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
) callconv(.C) void {
    const p = ptr orelse return;
    const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx orelse return));
    const a = std.mem.Alignment.fromByteUnits(alignment);
    const slice = @as([*]u8, @ptrCast(p))[0..size];
    zig_alloc.rawFree(slice, a, @returnAddress());
}

// System allocator backed by libc malloc. For alignments above
// max_align_t we over-allocate and stash the original pointer in a header.
const system_max_alignment: usize = @alignOf(c.max_align_t);

pub fn system() Allocator {
    return .{
        .alloc_fn = systemAlloc,
        .realloc_fn = systemRealloc,
        .free_fn = systemFree,
        .ctx = null,
    };
}

fn systemAlloc(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.C) ?*anyopaque {
    _ = ctx;

    if (alignment <= system_max_alignment) {
        return c.malloc(size);
    }

    const total = size + alignment + @sizeOf(usize);
    const raw = c.malloc(total) orelse return null;
    const raw_addr = @intFromPtr(raw);
    const aligned_addr = std.mem.alignForward(usize, raw_addr + @sizeOf(usize), alignment);
    const result: *anyopaque = @ptrFromInt(aligned_addr);
    const slot: *usize = @ptrFromInt(aligned_addr - @sizeOf(usize));
    slot.* = raw_addr;
    return result;
}

fn systemRealloc(
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    old_size: usize,
    new_size: usize,
    alignment: usize,
) callconv(.C) ?*anyopaque {
    _ = ctx;

    if (alignment <= system_max_alignment) {
        return c.realloc(ptr, new_size);
    }

    if (ptr == null) return systemAlloc(null, new_size, alignment);

    const new_ptr = systemAlloc(null, new_size, alignment) orelse return null;
    const copy_size = @min(old_size, new_size);
    @memcpy(
        @as([*]u8, @ptrCast(new_ptr))[0..copy_size],
        @as([*]const u8, @ptrCast(ptr.?))[0..copy_size],
    );
    systemFree(null, ptr, old_size, alignment);
    return new_ptr;
}

fn systemFree(
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    size: usize,
    alignment: usize,
) callconv(.C) void {
    _ = ctx;
    _ = size;

    const p = ptr orelse return;

    if (alignment <= system_max_alignment) {
        c.free(p);
        return;
    }

    const slot: *const usize = @ptrFromInt(@intFromPtr(p) - @sizeOf(usize));
    c.free(@ptrFromInt(slot.*));
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

test "system: realloc with high alignment preserves content" {
    const a = system();
    const p1 = a.alloc(16, 64) orelse return error.OutOfMemory;
    @memset(p1[0..16], 0xEE);

    const p2 = a.realloc(p1, 16, 128, 64) orelse {
        a.free(p1, 16, 64);
        return error.OutOfMemory;
    };
    defer a.free(p2, 128, 64);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p2) % 64);
    try std.testing.expectEqual(@as(u8, 0xEE), p2[0]);
    try std.testing.expectEqual(@as(u8, 0xEE), p2[15]);
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

test "toStd: ArrayList works through the bridge" {
    const a = system();
    var list = std.ArrayList(u8).init(a.toStd());
    defer list.deinit();

    try list.appendSlice("zarc");
    try std.testing.expectEqualSlices(u8, "zarc", list.items);
}

test "fromStd: bridge from std.mem.Allocator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const std_a = gpa.allocator();

    const a = fromStd(&std_a);

    const ptr = a.alloc(128, 8) orelse return error.OutOfMemory;
    defer a.free(ptr, 128, 8);

    @memset(ptr[0..128], 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), ptr[0]);
}

test "fromStd: realloc through bridge" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const std_a = gpa.allocator();

    const a = fromStd(&std_a);

    const p1 = a.alloc(32, 8) orelse return error.OutOfMemory;
    @memset(p1[0..32], 0x77);

    const p2 = a.realloc(p1, 32, 128, 8) orelse {
        a.free(p1, 32, 8);
        return error.OutOfMemory;
    };
    defer a.free(p2, 128, 8);

    try std.testing.expectEqual(@as(u8, 0x77), p2[0]);
    try std.testing.expectEqual(@as(u8, 0x77), p2[31]);
}

test "round-trip: toStd then fromStd" {
    const a = system();
    var std_a = a.toStd();
    const a2 = fromStd(&std_a);

    const ptr = a2.alloc(64, 8) orelse return error.OutOfMemory;
    defer a2.free(ptr, 64, 8);

    @memset(ptr[0..64], 0x55);
    try std.testing.expectEqual(@as(u8, 0x55), ptr[0]);
}