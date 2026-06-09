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
// Maybe change these using a new Type pattern to represent document logic
// that way they can be mutated independantly from drawing logic while being explicit
// and type safe
cy: u32 = 0,
cx: u32 = 0,
rx: u32 = 0,
file_name: ?[]const u8 = null,
msg: ?[]const u8 = null,
msg_time: std.Io.Timestamp,
io: std.Io,
writer: *Out,
buf_state: BufferState = .clean,
allocator: std.mem.Allocator,
scratch: std.heap.ArenaAllocator,

const VERSION = "0.1.0";
const TAB_WIDTH: usize = 4;

pub fn init(
    fd: std.posix.fd_t,
    writer: *Out,
    allocator: std.mem.Allocator,
    io: std.Io,
) !Editor {
    var editor: Editor = .{
        .fd = fd,
        .pt = try .init(allocator),
        .writer = writer,
        .allocator = allocator,
        .scratch = .init(allocator),
        .msg_time = std.Io.Clock.real.now(io),
        .io = io,
    };
    try editor.getWindowSize();
    editor.screen_rows -= 2;
    try editor.setStatusMsg("HELP: Ctrl-Q = quit", .{});

    return editor;
}

pub fn deinit(self: *Editor) void {
    self.pt.deinit();
    self.scratch.deinit();
    if (self.file_name) |p|
        self.allocator.free(p);
    if (self.msg) |m|
        self.allocator.free(m);
}

pub fn readFile(self: *Editor, io: std.Io, path: []const u8) !void {
    self.file_name = try self.allocator.dupe(u8, path);
    try self.pt.loadFile(io, path);
}

// Bitwise & the char with 00011111
// This sets the upper 3 bits of the character to 0
// Mirroring what the control key does to characters
fn controlKey(comptime c: u8) u8 {
    return c & 0x1f;
}

pub fn readKey(self: *const Editor) !Key {
    var p = Parser{};
    while (true) {
        var in: [1]u8 = undefined;
        const nread = std.posix.read(self.fd, &in) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (nread == 0) continue;
        if (p.feed(in[0])) |key| return key;
    }
}

fn centerLine(self: *const Editor, len: u16) u16 {
    if (len >= self.screen_cols) return 0;
    return (self.screen_cols - len) / 2;
}

pub fn insertChar(self: *Editor, ch: u8) !void {
    // Clamp on EOF
    const line_off = self.pt.offsetOfLine(self.cy + 1) orelse return;

    const off = line_off + self.cx;
    try self.pt.insert(off, &[_]u8{ch});
    if (ch == '\n') {
        self.cy += 1;
        self.cx = 0;
    } else {
        self.cx += 1;
    }
    self.buf_state = .dirty;
}

/// Returns the count of line feeds and the index of the last '\n'
fn countLFWithLast(text: []const u8) struct { count: u32, last_idx: ?usize } {
    const V = std.simd.suggestVectorLength(u8) orelse 16;

    // Only fall through to the optimized SIMD if the length warrants it
    if (text.len < V) {
        var lf: u32 = 0;
        var last: ?usize = null;
        for (text, 0..) |char, idx| {
            if (char == '\n') {
                lf += 1;
                last = idx;
            }
        }
        return .{ .count = lf, .last_idx = last };
    }

    const Chunk = @Vector(V, u8);
    const Mask = std.meta.Int(.unsigned, V);
    const splat: Chunk = @splat('\n');

    var last: ?usize = null;
    var lf: u32 = 0;
    var i: usize = 0;
    while (i + V <= text.len) : (i += V) {
        const chunk: Chunk = text[i..][0..V].*;
        const eq_bits: @Vector(V, u1) = @bitCast(chunk == splat);
        const mask: Mask = @bitCast(eq_bits);

        if (mask != 0) {
            lf += @popCount(mask);

            // Find the last match in the vector layout
            const last_match_in_chunk = @bitSizeOf(Mask) - 1 - @clz(mask);

            last = i + last_match_in_chunk;
        }
    }

    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            lf += 1;
            last = i;
        }
    }

    return .{
        .count = lf,
        .last_idx = last,
    };
}

pub fn insertString(self: *Editor, text: []const u8) !void {
    const line_off = self.pt.offsetOfLine(self.cy + 1) orelse return;
    const off = line_off + self.cx;
    try self.pt.insert(off, text);

    const new_lines = countLFWithLast(text);
    if (new_lines.last_idx) |idx| {
        self.cy += @intCast(new_lines.count);
        self.cx = @intCast(text.len - idx - 1);
    } else {
        self.cx += @intCast(text.len);
    }

    self.buf_state = .dirty;
}

pub fn backspace(self: *Editor) !void {
    if (self.cy == 0 and self.cx == 0) return;

    const line_off = self.pt.offsetOfLine(self.cy + 1) orelse return;

    // If we are in a line
    if (self.cx > 0) {
        try self.pt.delete(line_off + self.cx - 1, 1);
        self.cx -= 1;
        // If a line is empty go back to the previous line
    } else {
        const prev_len = self.pt.getLineLength(self.cy);
        try self.pt.delete(line_off - 1, 1);
        self.cy -= 1;
        self.cx = prev_len;
    }
    self.buf_state = .dirty;
}

pub fn delete(self: *Editor) !void {
    const total = self.pt.totalLines();
    if (total == 0) return;

    const line_off = self.pt.offsetOfLine(self.cy + 1) orelse return;
    const line_len = self.pt.getLineLength(self.cy + 1);

    if (self.cx < line_len) {
        try self.pt.delete(line_off + self.cx, 1);
    } else if (self.cy + 1 < total) {
        try self.pt.delete(line_off + line_len, 1);
    } else return;

    self.buf_state = .dirty;
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
            var col: usize = 0;
            for (line) |char| {
                if (col >= self.screen_cols) break;
                if (char == '\t') {
                    const spaces_needed = TAB_WIDTH - (col % TAB_WIDTH);
                    const spaces_to_print = @min(spaces_needed, self.screen_cols - col);
                    try self.writer.splatByteAll(' ', spaces_to_print);
                    col += spaces_to_print;
                } else {
                    try self.writer.writeByte(char);
                    col += 1;
                }
            }
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
                try self.writer.writeByte('~');
                pad -= 1;
            }

            while (pad > 0) : (pad -= 1) try self.writer.writeByte(' ');
            try self.writer.print("{s}", .{msg[0..len]});
        } else {
            try self.writer.writeByte('~');
        }

        // Clear each line as we draw it, Erase in Line
        try self.writer.writeSlice("\x1b[K");
        try self.writer.writeSlice("\r\n");
    }
    try self.writer.flush();
}

pub fn setStatusMsg(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
    var buf: [80]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt, args);
    self.msg = try self.allocator.dupe(u8, msg);
    self.msg_time = std.Io.Clock.real.now(self.io);
}

fn drawMsg(self: *Editor) !void {
    try self.writer.writeSlice("\x1b[K");

    const msg = self.msg orelse return;

    const elapsed = self.msg_time.untilNow(self.io, .real);

    if (elapsed.toSeconds() >= 5) {
        return;
    }

    var len = msg.len;
    if (len > self.screen_cols) {
        len = self.screen_cols;
    }

    try self.writer.writeSlice(msg[0..len]);
}

fn drawStatus(self: *Editor) !void {
    // Select graphic rendition
    // 1 bold, 4 underscore, 5 blink, 7 inverted color
    try self.writer.writeSlice("\x1b[7m");
    const lines = self.pt.totalLines();

    var buf: [80]u8 = undefined;
    const file = try std.fmt.bufPrint(
        &buf,
        "{[str]s:.[width]} -- {[lines]d} lines {[mod]s}",
        .{
            .str = if (self.file_name) |n| n else "[No File]",
            .width = if (self.file_name) |n| n.len else 20,
            .lines = lines,
            .mod = if (self.buf_state == .dirty) "(modified)" else "",
        },
    );
    // try self.writer.print("{s}", .{file});
    try self.writer.writeSlice(file);

    var len: usize = file.len;

    const l = try std.fmt.bufPrint(&buf, "{d}/{d}", .{ self.cy + 1, lines });

    while (len < self.screen_cols) : (len += 1) {
        if (self.screen_cols - len == l.len) {
            try self.writer.writeSlice(l);
            break;
        } else {
            try self.writer.writeByte(' ');
        }
    }
    // Clear all arguments to go back to normal
    try self.writer.writeSlice("\x1b[m");
    try self.writer.writeSlice("\r\n");
    try self.writer.flush();
}

fn cxToRx(cx: u32, line: []const u8) u32 {
    var rx: u32 = 0;
    var i: u32 = 0;
    while (i < cx and i < line.len) : (i += 1) {
        if (line[i] == '\t') {
            rx += @intCast(TAB_WIDTH - (rx % TAB_WIDTH));
        } else rx += 1;
    }
    return rx;
}

fn scroll(self: *Editor) !void {
    self.rx = 0;
    if (self.cy < self.pt.totalLines()) {
        const line = try self.pt.getLineContent(
            self.scratch.allocator(),
            (self.cy + 1),
        );
        self.rx = cxToRx(self.cx, line);
    }

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
    try self.writer.writeSlice("\x1b[?25l");
    // Set the cursor at the corner with the H command
    try self.writer.writeSlice("\x1b[H");

    try self.scroll();
    try self.drawRows();
    try self.drawStatus();
    try self.drawMsg();

    // Place cursor at end of line
    try self.writer.print("\x1b[{d};{d}H", .{
        (self.cy - self.row_offset) + 1,
        self.rx + 1,
    });

    // Redraw the cursor, Set Mode
    try self.writer.writeSlice("\x1b[?25h");

    try self.writer.flush();
}

pub fn saveFile(self: *Editor) !void {
    // TODO: Prompt the user for a save file name for now itll be a no op
    if (self.file_name) |n| {
        const cwd = std.Io.Dir.cwd();

        const dir = std.Io.Dir.path.dirname(n);
        const base = std.Io.Dir.path.basename(n);

        const p = if (dir) |d|
            try std.fmt.allocPrint(self.allocator, "{s}/.tmp.{s}", .{ d, base })
        else
            try std.fmt.allocPrint(self.allocator, ".tmp.{s}", .{base});
        defer self.allocator.free(p);

        var f = try cwd.createFile(self.io, p, .{});
        errdefer cwd.deleteFile(self.io, p) catch {};
        defer f.close(self.io);

        const bytes = try self.pt.collectDoc(self.allocator);
        defer self.allocator.free(bytes);

        // Preallocate a page for the buffered writer
        var file_buffer: [4096]u8 = undefined;
        var writer = f.writer(self.io, &file_buffer);

        try writer.interface.writeAll(bytes);
        try writer.interface.flush();

        // Rudimentary guard, a better solution probably exists though
        const s = try f.stat(self.io);
        if (s.size != bytes.len) {
            try self.setStatusMsg("Failed to save file", .{});
        } else {
            try cwd.rename(p, std.Io.Dir.cwd(), n, self.io);
            try self.setStatusMsg("File saved: {} bytes written to disk", .{s.size});
        }
        self.buf_state = .clean;
    }
}

pub fn getCursorPos(self: *Editor) !void {
    var buf: [32]u8 = undefined;
    var i: u16 = 0;

    // Cursor position report
    try self.writer.writeSlice("\x1b[6n");
    try self.writer.writeSlice("\r\n");
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
    const semi = std.mem.findScalar(u8, payload, ';') orelse return error.BadEscape;

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
        try self.writer.writeSlice("\x1b[999C\x1b[999B");
        try self.writer.flush();
        try self.getCursorPos();
    } else {
        self.screen_cols = ws.col;
        self.screen_rows = ws.row;
    }
}

pub fn pageUp(self: *Editor) void {
    self.cy = self.row_offset; // top of view port
    var n = self.screen_rows;
    while (n > 0 and self.cy > 0) : (n -= 1) self.cy -= 1;
}

pub fn pageDown(self: *Editor) void {
    const total = self.pt.totalLines();
    // Guard against underflows
    if (total == 0 or self.screen_rows == 0) return;
    self.cy = self.row_offset + self.screen_rows - 1; // bottom of viewport
    if (self.cy >= total) self.cy = total - 1;
    var n = self.screen_rows;
    while (n > 0 and self.cy + 1 < total) : (n -= 1) self.cy += 1;
}

pub fn home(self: *Editor) void {
    self.cx = 0;
}

pub fn end(self: *Editor) void {
    self.cx = self.screen_cols - 1;
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

const BufferState = enum(u1) { clean, dirty };

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

const Parser = struct {
    state: enum { ground, esc, csi, ss3 } = .ground,
    params: [8]u16 = std.mem.zeroes([8]u16),
    n: usize = 0,

    /// Resets the parse to default state
    fn reset(p: *Parser) void {
        p.* = .{};
    }

    /// Return the param stored in the buffer. Bounds safe op.
    fn param(p: *const Parser, i: usize) u16 {
        return if (i < p.n) p.params[i] else 0;
    }

    /// Feeds tokens into the Parser
    /// follows a simple state machine given the type of key press
    fn feed(p: *Parser, b: u8) ?Key {
        switch (p.state) {
            .ground => {
                if (b == '\x1b') {
                    p.state = .esc;
                    return null;
                }
                return .{ .char = b };
            },
            .esc => switch (b) {
                '[' => {
                    p.state = .csi;
                    p.n = 1;
                    return null;
                },
                'O' => {
                    p.state = .ss3;
                    return null;
                },
                else => {
                    p.reset();
                    return .{ .char = b };
                }, // bare ESC / Alt-key
            },
            .csi => {
                if (b >= '0' and b <= '9') {
                    // Saturating arithmetic instead of standard ops
                    // this simply translates to:
                    //      value = value * 10 + digit
                    // the saturating op clamps to maxInt(u16) so that a bad
                    // input doesn't blow up into an overflow
                    p.params[p.n - 1] = p.params[p.n - 1] *| 10 +| (b - '0');
                    return null;
                }
                if (b == ';') {
                    if (p.n < p.params.len) p.n += 1;
                    return null;
                }
                defer p.reset();
                return p.dispatchCsi(b);
            },
            .ss3 => {
                defer p.reset();
                return dispatchSs3(b);
            },
        }
    }

    /// Parse Control Sequence Introducer commands
    /// fit the form \x1b[
    fn dispatchCsi(p: *const Parser, final: u8) Key {
        return switch (final) {
            'A' => .arrow_up,
            'B' => .arrow_down,
            'C' => .arrow_right,
            'D' => .arrow_left,
            'H' => .home,
            'F' => .end,
            '~' => switch (p.param(0)) {
                1, 7 => .home,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => .{ .char = '\x1b' },
            },
            else => .{ .char = '\x1b' },
        };
    }

    /// Parse Single Shift 3, in the form \x1b O.
    /// Like CSI but simpler
    fn dispatchSs3(final: u8) Key {
        return switch (final) {
            'H' => .home,
            'F' => .end,
            else => .{ .char = '\x1b' },
        };
    }
};

test "countLFWithLast - SIMD and scalar edge cases" {
    const testing = std.testing;

    const res1 = countLFWithLast("");
    try testing.expectEqual(@as(u32, 0), res1.count);
    try testing.expectEqual(@as(?usize, null), res1.last_idx);

    const res2 = countLFWithLast("Hello World!");
    try testing.expectEqual(@as(u32, 0), res2.count);
    try testing.expectEqual(@as(?usize, null), res2.last_idx);

    const res3 = countLFWithLast("Hello\n");
    try testing.expectEqual(@as(u32, 1), res3.count);
    try testing.expectEqual(@as(?usize, 5), res3.last_idx);

    const res4 = countLFWithLast("Line1\nLine2\nLine3\nEnding");
    try testing.expectEqual(@as(u32, 3), res4.count);
    // 'g' is at 23, last '\n' is right before 'Ending' (length 6), so index 17
    try testing.expectEqual(@as(?usize, 17), res4.last_idx);

    const long_text = "a\n" ** 50; // 100 bytes long
    const res5 = countLFWithLast(long_text);
    try testing.expectEqual(@as(u32, 50), res5.count);
    try testing.expectEqual(@as(?usize, 99), res5.last_idx);
}
