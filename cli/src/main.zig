//! zarc CLI entry point.

const std = @import("std");
const zarcutil = @import("zarcutil");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("zarc v{s} -- nothing works yet\n", .{zarcutil.version});
}

test "cli runs" {
    try std.testing.expect(true);
}
