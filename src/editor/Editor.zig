const std = @import("std");
pub const Editor = @This();
const Out = @import("../util/printer.zig").Out;

screen_rows: u16,
screen_cols: u16,

pub fn init(r: u16, c: u16) Editor {
    return .{
        .screen_rows = r,
        .screen_cols = c,
    };
}

// Bitwise & the char with 00011111
// This sets the upper 3 bits of the character to 0
// Mirroring what the control key does to characters
fn controlKey(comptime c: u8) u8 {
    return c & 0x1f;
}

pub fn readKey(self: *const Editor, fd: std.posix.fd_t) !u8 {
    _ = self;
    var in: [1]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &in);
        if (n == 0) continue;

        return in[0];
    }
}

fn drawRows(self: *const Editor, out: *Out) !void {
    var y: usize = 0;
    while (y < self.screen_cols) : (y += 1) {
        try out.print("~\r\n", .{});
    }
    try out.flush();
}

pub fn refresh(self: *const Editor, out: *Out) !void {
    // \x1b is 27 in decimal
    // here we clear the screen with the J command, the 2 argument clears
    // the entire screen
    try out.print("\x1b[2J", .{});
    // Set the cursor at the corner with the H command
    try out.print("\x1b[H", .{});

    try self.drawRows(out);

    try out.print("\x1b[H", .{});
    try out.flush();
}
