//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub fn printAnotherMessage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}
