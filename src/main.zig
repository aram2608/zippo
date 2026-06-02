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
}
