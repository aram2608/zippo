const std = @import("std");

pub const Out = struct {
    fw: std.Io.File.Writer,

    pub fn init(io: std.Io, buffer: []u8) Out {
        return .{ .fw = .init(.stdout(), io, buffer) };
    }

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        try self.fw.interface.print(fmt, args);
    }

    pub fn flush(self: *Out) !void {
        try self.fw.interface.flush();
    }
};
