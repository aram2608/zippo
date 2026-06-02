const std = @import("std");
const Io = std.Io;

const zippo = @import("zippo");

const Out = struct {
    fw: std.Io.File.Writer,

    pub fn init(io: Io, buffer: []u8) Out {
        return .{ .fw = .init(.stdout(), io, buffer) };
    }

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        try self.fw.interface.print(fmt, args);
    }

    pub fn flush(self: *Out) !void {
        try self.fw.interface.flush();
    }
};

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
    var out = Out.init(io, &buf);
    try out.print("foo {d}\n", .{42});
    try out.flush();

    const fd = std.posix.STDIN_FILENO;

    const termios = try std.posix.tcgetattr(fd);
    defer _ = std.posix.tcsetattr(fd, .NOW, termios) catch {};

    var raw = termios;

    // Shut off Ctrl-M
    raw.iflag.ICRNL = false;
    // Shut of software flow control
    raw.iflag.IXON = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INPCK = false;
    raw.iflag.BRKINT = false;

    // Shut off output processing, -> \r\n
    raw.oflag.OPOST = false;

    // Set the character to 8 bytes
    raw.cflag.CSIZE = .CS8;

    // Prevent printing to term
    raw.lflag.ECHO = false;
    // Switch to raw mode
    raw.lflag.ICANON = false;
    // Shut off Ctrl-v
    raw.lflag.IEXTEN = false;
    // Shut off Ctrl-C
    raw.lflag.ISIG = false;

    // Set to 0 so that i returns as soon an input is provided
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    // Set to 1 so it waits 1/10 of a second before returning
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

    try std.posix.tcsetattr(fd, std.posix.TCSA.FLUSH, raw);

    var in: [1]u8 = undefined;
    while (true) {
        const byte = try std.posix.read(fd, &in);
        const c = in[0];
        if (byte == 1 and c == 'q') {
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
