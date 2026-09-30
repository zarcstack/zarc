const std = @import("std");
const zarcutil = @import("zarcutil");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "zarc v" ++ zarcutil.version ++ " -- nothing works yet\n");
}

test "cli runs" {
    try std.testing.expect(true);
}
