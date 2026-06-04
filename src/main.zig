const std = @import("std");
const zippo = @import("zippo");
const Io = std.Io;

// Bitwise & the char with 00011111
// This sets the upper 3 bits of the character to 0
// Mirroring what the control key does to characters
fn controlKey(comptime c: u8) u8 {
    return c & 0x1f;
}

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var out = zippo.Out.init(io, &buf);
    errdefer {
        out.print("\x1b[2J", .{}) catch {};
        out.print("\x1b[H", .{}) catch {};
        out.flush() catch {};
    }

    const fd = std.posix.STDIN_FILENO;

    const raw = try zippo.RawMode.init(fd);
    defer raw.deinit();

    // Long-lived allocator for the piece tree; supports real free as edits delete nodes.
    const gpa = std.heap.smp_allocator;

    var e = try zippo.Editor.init(raw.fd, &out, gpa);
    defer e.deinit();

    try e.getWindowSize();

    while (true) {
        try e.refresh();

        const c = try e.readKey();

        switch (c) {
            .char => |ch| switch (ch) {
                controlKey('q') => {
                    try out.print("\x1b[2J", .{});
                    try out.print("\x1b[H", .{});
                    try out.flush();
                    break;
                },
                '\r' => try e.insertChar('\n'),
                else => try e.insertChar(ch),
            },
            .arrow_left => e.moveCursor(c),
            .arrow_down => e.moveCursor(c),
            .arrow_up => e.moveCursor(c),
            .arrow_right => e.moveCursor(c),
            .page_down, .page_up => {
                var times = e.screen_rows;
                while (times > 0) : (times -= 1) {
                    e.moveCursor(if (c == .page_up) .arrow_up else .arrow_down);
                }
            },
            .home => e.cx = 0,
            .end => e.cx = e.screen_cols - 1,
            .delete => {},
        }
    }
}
