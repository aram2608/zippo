//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const RawMode = @import("term/RawMode.zig");
pub const Out = @import("util/printer.zig").Out;
pub const Editor = @import("editor/Editor.zig").Editor;
pub const PieceTree = @import("buffer/PieceTree.zig");

pub fn printAnotherMessage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

test "All tests" {
    _ = @import("buffer/PieceTree.zig");
    _ = @import("editor/Editor.zig");
}
