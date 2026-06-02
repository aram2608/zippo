const std = @import("std");
const zippo = @import("zippo");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var out = zippo.Out.init(io, &buf);
    try out.print("foo {d}\n", .{42});
    try out.flush();

    const fd = std.posix.STDIN_FILENO;

    const raw = try zippo.RawMode.init(fd);
    defer raw.deinit();

    var in: [1]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &in);
        if (n == 0) continue;

        const c = in[0];
        if (n == 1 and c == 'q') {
            break;
        } else if (std.ascii.isControl(c)) {
            try out.print("{d}\r\n", .{c});
            try out.flush();
        } else {
            try out.print("{c}\r\n", .{c});
            try out.flush();
        }
    }
}
