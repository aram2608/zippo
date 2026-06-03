const std = @import("std");
const zippo = @import("zippo");
const Io = std.Io;

// Bitwise & the char with 00011111
// This sets the upper 3 bits of the character to 0
// Mirroring what the control key does to characters
fn controlKey(comptime c: u8) u8 {
    return c & 0x1f;
}

fn getWindowSize(rows: *u16, cols: *u16) !void {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&ws),
    );
    if (std.posix.errno(rc) != .SUCCESS or ws.col == 0) return error.GetWindowSizeFailed;
    cols.* = ws.col;
    rows.* = ws.row;
}

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    // const arena: std.mem.Allocator = init.arena.allocator();

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var out = zippo.Out.init(io, &buf);

    const fd = std.posix.STDIN_FILENO;

    const raw = try zippo.RawMode.init(fd);
    defer raw.deinit();

    var screen_rows: u16 = undefined;
    var screen_cols: u16 = undefined;

    try getWindowSize(&screen_rows, &screen_cols);

    const e = zippo.Editor.init(screen_rows, screen_cols);

    while (true) {
        try e.refresh(&out);

        const c = try e.readKey(fd);

        switch (c) {
            controlKey('q') => {
                try out.print("\x1b[2J", .{});
                try out.print("\x1b[H", .{});
                try out.flush();
                break;
            },
            else => {},
        }
    }
}
