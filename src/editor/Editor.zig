const std = @import("std");
pub const Editor = @This();
const PieceTree = @import("../buffer/PieceTree.zig");
const Out = @import("../util/printer.zig").Out;

// CLRF, Carriage Return Line Feed \r\n

fd: std.posix.fd_t,
screen_rows: u16 = 0,
screen_cols: u16 = 0,
row_offset: u32 = 0,
pt: PieceTree,
cy: u32 = 0,
cx: u32 = 0,
writer: *Out,
scratch: std.heap.ArenaAllocator,

const VERSION = "0.1.0";

pub fn init(
    fd: std.posix.fd_t,
    writer: *Out,
    allocator: std.mem.Allocator,
) !Editor {
    return .{
        .fd = fd,
        .pt = try PieceTree.init(allocator),
        .writer = writer,
        .scratch = .init(allocator),
    };
}

pub fn deinit(self: *Editor) void {
    self.pt.deinit();
    self.scratch.deinit();
}

pub fn readFile(self: *Editor, io: std.Io, path: []const u8) !void {
    try self.pt.loadFile(io, path);
}

// Bitwise & the char with 00011111
// This sets the upper 3 bits of the character to 0
// Mirroring what the control key does to characters
fn controlKey(comptime c: u8) u8 {
    return c & 0x1f;
}

fn readByte(self: *const Editor) ?u8 {
    var b: [1]u8 = undefined;
    const n = std.posix.read(self.fd, &b) catch return null;
    return if (n == 1) b[0] else null;
}

pub fn readKey(self: *const Editor) !Key {
    var in: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(self.fd, &in) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 1) break;
    }

    if (in[0] != '\x1b') return .{ .char = in[0] };

    const b0 = self.readByte() orelse return .{ .char = '\x1b' };
    const b1 = self.readByte() orelse return .{ .char = '\x1b' };

    if (b0 == '[') {
        if (b1 >= '0' and b1 <= '9') {
            const b2 = self.readByte() orelse return .{ .char = '\x1b' };
            if (b2 == '~') return switch (b1) {
                '1' => .home,
                '3' => .delete,
                '4' => .end,
                '5' => .page_up,
                '6' => .page_down,
                '7' => .home,
                '8' => .end,
                else => .{ .char = '\x1b' },
            };
        } else return switch (b1) {
            'A' => .arrow_up,
            'B' => .arrow_down,
            'C' => .arrow_right,
            'D' => .arrow_left,
            'H' => .home,
            'F' => .end,
            else => .{ .char = '\x1b' },
        };
    } else if (b0 == 'O') return switch (b1) {
        'H' => .home,
        'F' => .end,
        else => .{ .char = '\x1b' },
    };

    return .{ .char = '\x1b' };
}

fn centerLine(self: *const Editor, len: u16) u16 {
    if (len >= self.screen_cols) return 0;
    return (self.screen_cols - len) / 2;
}

pub fn insertChar(self: *Editor, ch: u8) !void {
    // Clamp on EOF
    const line_off = self.pt.offsetOfLine(self.cy + 1) orelse {
        return;
    };
    const off = line_off + self.cx;
    try self.pt.insert(off, &[_]u8{ch});
    if (ch == '\n') {
        self.cy += 1;
        self.cx = 0;
    } else {
        self.cx += 1;
    }
}

fn drawRows(self: *Editor) !void {
    const total = self.pt.totalLines();
    var y: u32 = 0;
    while (y < self.screen_rows) : (y += 1) {
        const row = y + self.row_offset;
        if (row < total) {
            const line = try self.pt.getLineContent(
                self.scratch.allocator(),
                (row + 1),
            );
            const len = @min(line.len, self.screen_cols);
            try self.writer.print("{s}", .{line[0..len]});
        } else if (total == 0 and y == self.screen_rows / 3) {
            var buf: [80]u8 = undefined;
            const msg = try std.fmt.bufPrint(
                &buf,
                "zippo -- version {s}",
                .{VERSION},
            );
            const len = @min(msg.len, self.screen_cols);
            var pad = self.centerLine(len);

            if (pad > 0) {
                try self.writer.print("~", .{});
                pad -= 1;
            }

            while (pad > 0) : (pad -= 1) try self.writer.print(" ", .{});
            try self.writer.print("{s}", .{msg[0..len]});
        } else {
            try self.writer.print("~", .{});
        }

        // Clear each line as we draw it, Erase in Line
        try self.writer.print("\x1b[K", .{});
        if (self.screen_rows > 0 and y + 1 < self.screen_rows)
            try self.writer.print("\r\n", .{});
    }
    try self.writer.flush();
}

fn scroll(self: *Editor) void {
    if (self.cy < self.row_offset) {
        self.row_offset = self.cy;
    }
    if (self.screen_rows > 0 and self.cy >= self.row_offset + self.screen_rows) {
        self.row_offset = self.cy - self.screen_rows + 1;
    }
}

pub fn refresh(self: *Editor) !void {
    // \x1b is 27 in decimal

    _ = self.scratch.reset(.retain_capacity);

    // Hide cursor during refresh, Reset Mode
    try self.writer.print("\x1b[?25l", .{});
    // Set the cursor at the corner with the H command
    try self.writer.print("\x1b[H", .{});

    self.scroll();
    try self.drawRows();

    try self.writer.print("\x1b[{d};{d}H", .{
        (self.cy - self.row_offset) + 1,
        self.cx + 1,
    });

    // Redraw the cursor, Set Mode
    try self.writer.print("\x1b[?25h", .{});

    try self.writer.flush();
}

pub fn getCursorPos(self: *Editor) !void {
    var buf: [32]u8 = undefined;
    var i: u16 = 0;

    // Cursor position report
    try self.writer.print("\x1b[6n", .{});
    try self.writer.print("\r\n", .{});
    try self.writer.flush();

    while (i < buf.len - 1) : (i += 1) {
        const n = std.posix.read(self.fd, buf[i .. i + 1]) catch break;
        if (n != 1) break;
        if (buf[i] == 'R') break;
    }
    buf[i] = 0;

    if (i < 2 or buf[0] != '\x1b' or buf[1] != '[') return error.BadEscape;

    // Zig does not have a sccanf so we need to extract the payload then calc
    // the location to the `;`.
    const payload = buf[2..i];
    const semi = std.mem.indexOfScalar(u8, payload, ';') orelse return error.BadEscape;
    // We can then parse an int from the index of the `;` in decimal.
    self.screen_rows = try std.fmt.parseInt(u16, payload[0..semi], 10);
    self.screen_cols = try std.fmt.parseInt(u16, payload[semi + 1 ..], 10);
}

pub fn getWindowSize(self: *Editor) !void {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&ws),
    );
    if (std.posix.errno(rc) != .SUCCESS or ws.col == 0 or ws.row == 0) {
        // C command is the Cursor forward
        // B command is Cursor down
        // There is no easy way to get the cursor position so we use this hack
        // to roughly calc it if the .ioctl call fails
        try self.writer.print("\x1b[999C\x1b[999B", .{});
        try self.writer.flush();
        try self.getCursorPos();
    } else {
        self.screen_cols = ws.col;
        self.screen_rows = ws.row;
    }
}

pub fn moveCursor(self: *Editor, key: Key) void {
    switch (key) {
        .arrow_left => {
            if (self.cx != 0) self.cx -= 1;
        },
        .arrow_right => {
            if (self.screen_cols > 0 and self.cx + 1 < self.screen_cols) self.cx += 1;
        },
        .arrow_up => {
            if (self.cy != 0) self.cy -= 1;
        },
        .arrow_down => {
            if (self.cy + 1 < self.pt.totalLines()) self.cy += 1;
        },
        else => {},
    }
    const line_len = self.pt.getLineLength(self.cy + 1);
    if (self.cx > line_len) self.cx = line_len;
}

const Key = union(enum) {
    char: u8,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    page_up,
    page_down,
    home,
    end,
    delete,
};
