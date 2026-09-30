//! libzarcutil -- the runtime every other zarc library depends on.

pub const memory = @import("memory.zig");

test {
    @import("std").testing.refAllDecls(@This());
}