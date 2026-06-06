//! A simple utility module for printing to the STDOUT.
//! Wraps the lower level calls to the std.Io.File.Writer.Interface to simplify
//! call site usage.
//!
//! Traditionally, a
//!     var fwi = &fw.interface;
//! handle is needed everywhere a call is made to the underlying interface.
//! The reference is important since the internal data is modified after each call.
//! By using the Out object, this cognitive overhead can be avoided.
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

    pub fn splatByteAll(self: *Out, c: u8, n: usize) !void {
        try self.fw.interface.splatByteAll(c, n);
    }

    pub fn writeByte(self: *Out, c: u8) !void {
        try self.fw.interface.writeByte(c);
    }

    /// Wraps writeAll. Prints all bytes to stream.
    pub fn writeSlice(self: *Out, slice: []const u8) !void {
        try self.fw.interface.writeAll(slice);
    }
};
