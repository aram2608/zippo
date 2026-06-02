const std = @import("std");
const RawMode = @This();

fd: std.posix.fd_t,
og_termios: std.posix.termios,

pub fn init(fd: std.posix.fd_t) !RawMode {
    const termios = try std.posix.tcgetattr(fd);

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

    // Set the character to 8 bits
    raw.cflag.CSIZE = .CS8;

    // Prevent printing to terminal
    raw.lflag.ECHO = false;
    // Switch to raw mode
    raw.lflag.ICANON = false;
    // Shut off Ctrl-v
    raw.lflag.IEXTEN = false;
    // Shut off Ctrl-C
    raw.lflag.ISIG = false;

    // Set to 0 so that it returns as soon an input is provided
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    // Set to 1 so it waits 1/10 of a second before returning
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

    try std.posix.tcsetattr(fd, .FLUSH, raw);

    return .{
        .fd = fd,
        .og_termios = termios,
    };
}

pub fn deinit(self: *const RawMode) void {
    _ = std.posix.tcsetattr(self.fd, .FLUSH, self.og_termios) catch {};
}
