const std = @import("std");
const PieceTree = @This();

allocator: std.mem.Allocator,
buffers: std.ArrayList(Buffer) = .empty,
root: *Node,
sentinel: *Node,
last_change_pos: u32 = 0,

pub fn init(allocator: std.mem.Allocator) !PieceTree {
    // Instead of a ?*Node architexture we store a sentinel value
    // VSCode style to safely check nodes
    const sentinel = try allocator.create(Node);
    sentinel.* = .{
        .parent = sentinel,
        .left = sentinel,
        .right = sentinel,
        .color = .black,
        .piece = .{ .idx = .change, .start = 0, .len = 0, .line_feeds = 0 },
        .size_left = 0,
        .lf_left = 0,
    };

    var t = PieceTree{
        .allocator = allocator,
        .root = sentinel,
        .sentinel = sentinel,
    };
    try t.buffers.append(allocator, .{});
    try t.buffers.items[0].line_starts.append(allocator, 0);
    return t;
}

pub fn deinit(self: *PieceTree) void {
    self.freeSubtree(self.root);
    self.allocator.destroy(self.sentinel);
    for (self.buffers.items) |*b| b.deinit(self.allocator);
    self.buffers.deinit(self.allocator);
}

fn freeSubtree(self: *PieceTree, node: *Node) void {
    if (node == self.sentinel) return;
    self.freeSubtree(node.left);
    self.freeSubtree(node.right);
    self.allocator.destroy(node);
}

/// Resolve a piece's bytes on demand (re-indexing into the live buffer).
fn pieceBytes(self: *PieceTree, p: Piece) []const u8 {
    const b = self.buffers.items[@intFromEnum(p.buffer)].bytes.items;
    return b[p.start .. p.start + p.len];
}

fn leftRotate(self: *PieceTree, x: *Node) void {
    const y = x.right;

    // y's left subtree gains x plus x's former left subtree.
    y.size_left += x.size_left + x.piece.len;
    y.lf_left += x.lf_left + x.piece.line_feeds;

    x.right = y.left;
    if (y.left != self.sentinel) y.left.parent = x;
    y.parent = x.parent;

    if (x.parent == self.sentinel) {
        self.root = y;
    } else if (x == x.parent.left) {
        x.parent.left = y;
    } else {
        x.parent.right = y;
    }
    y.left = x;
    x.parent = y;
}

fn rightRotate(self: *PieceTree, y: *Node) void {
    const x = y.left;

    // y loses x plus x's left subtree from its left side.
    y.size_left -= x.size_left + x.piece.len;
    y.lf_left -= x.lf_left + x.piece.line_feeds;

    y.left = x.right;
    if (x.right != self.sentinel) x.right.parent = y;
    x.parent = y.parent;

    if (y.parent == self.sentinel) {
        self.root = x;
    } else if (y == y.parent.right) {
        y.parent.right = x;
    } else {
        y.parent.left = x;
    }
    x.right = y;
    y.parent = x;
}

pub fn nodeAt(self: *PieceTree, offset_in: u32) ?Position {
    var x = self.root;
    var offset = offset_in;
    var node_start: u32 = 0;
    while (x != self.sentinel) {
        if (x.size_left > offset) {
            x = x.left;
        } else if (x.size_left + x.piece.len >= offset) {
            node_start += x.size_left;
            return .{
                .node = x,
                .remainder = offset - x.size_left,
                .node_start_offset = node_start,
            };
        } else {
            offset -= x.size_left + x.piece.len;
            node_start += x.size_left + x.piece.len;
            x = x.right;
        }
    }
    return null;
}

fn appendToChangeBuffer(self: *PieceTree, text: []const u8) !Piece {
    const buf = &self.buffers.items[0];
    const start: u32 = @intCast(buf.bytes.items.len);

    try buf.bytes.appendSlice(self.allocator, text);
    var lf: u32 = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            lf += 1;
            // Calculate 1 value past the `\n` as it is a new line
            try buf.line_starts.append(self.allocator, start + @as(
                u32,
                @intCast(i),
            ) + 1);
        }
    }

    // Each append returns a new Piece with indexes into the buffer
    // Memory allocations in Zig can change the location of the data
    // This prevents saving slices of data since they can end up pointing at junk
    return .{
        .idx = .change,
        .start = start,
        .len = @intCast(text.len),
        .line_feeds = lf,
    };
}

pub fn insert(self: *PieceTree, offset: u32, text: []const u8) !void {
    if (self.root != self.sentinel) {
        const pos = self.nodeAt(offset).?;
        const piece = pos.node.piece;
        const idx = piece.idx;
        // Hot-Path for typing, we simply bump the node length given the length
        // of the input text
        // The char is input from the last touched piece so we do not have to
        // make a new one
        if (idx == .change and piece.start + piece.len == self.last_change_pos and pos.node_start_offset + piece.len == offset) {
            const np = try self.appendToChangeBuffer(text);
            self.updateMetadata(pos.node, np.len, np.line_feeds);
            @panic("write a test case for this insert");
        }

        // Node boundary insert
        if (pos.node_start_offset == offset) {
            @panic("insertToNodeLeft not impl");
            // Mid node split, you have one piece [A | B] and want [A | NEW | B].
        } else if (pos.node_start_offset + piece.len > offset) {
            @panic("implement mid node insertions");
            // Add to the end of the node
        } else {
            @panic("insertToNodeRight not impl");
        }
        // Graft brand new nodes
    } else {
        const np = try self.appendToChangeBuffer(text);
        _ = try self.insertLeft(null, np);
    }
}

fn insertLeft(self: *PieceTree, node: ?*Node, p: Piece) !*Node {
    var z = try self.allocator.create(Node);
    z.* = .{
        .piece = p,
        .parent = self.sentinel,
        .left = self.sentinel,
        .right = self.sentinel,
        .color = .red,
        .size_left = 0,
        .lf_left = 0,
    };

    if (self.root == self.sentinel) {
        self.root = z;
        z.color = .black;
    } else if (node.?.left == self.sentinel) {
        node.?.left = z;
        z.parent = node.?;
    } else {
        var pn = self.rightmost(node.?.left);
        pn.right = z;
        z.parent = pn;
    }

    // TODO: Fix on insert
    self.fixInsert(z);
    self.updateMetadata(z, p.len, p.line_feeds);

    return z;
}

fn fixInsert(self: *PieceTree, n: *Node) void {
    var x = n;
    while (x != self.root and x.parent.color == .red) {
        if (x.parent == x.parent.parent.left) {
            var y = x.parent.parent.right;
            switch (y.color) {
                .red => {
                    x.parent.color = .black;
                    y.color = .black;
                    x.parent.parent.color = .red;
                    x = x.parent.parent;
                },
                .black => {
                    if (x == x.parent.right) {
                        x = x.parent;
                        self.leftRotate(x);
                    }

                    x.parent.color = .black;
                    x.parent.parent.color = .red;
                    self.rightRotate(x.parent.parent);
                },
            }
        } else {
            var y = x.parent.parent.left;
            switch (y.color) {
                .red => {
                    x.parent.color = .black;
                    y.color = .black;
                    x.parent.parent.color = .red;
                    x = x.parent.parent;
                },
                .black => {
                    if (x == x.parent.left) {
                        x = x.parent;
                        self.rightRotate(x);
                    }
                    x.parent.color = .black;
                    x.parent.parent.color = .red;
                    self.leftRotate(x.parent.parent);
                },
            }
        }
    }

    self.root.color = .black;
}

fn rightmost(self: *const PieceTree, start: *Node) *Node {
    var n = start;
    while (n.right != self.sentinel) {
        n = n.right;
    }
    return n;
}

fn leftmost(self: *const PieceTree, start: *Node) *Node {
    var n = start;
    while (n.left != self.sentinel) {
        n = n.left;
    }
    return n;
}

/// Walk the tree upwards and propogate metadata
/// (ie. line feed count changes or node length changes)
/// The math here is a bit dangerous since delta's can be negative
fn updateMetadata(
    self: *PieceTree,
    node: *Node,
    byte_delta: i64,
    lf_delta: i64,
) void {
    var x = node;
    while (x != self.root and x != self.sentinel) {
        if (x.parent.left == x) {
            x.parent.size_left = @intCast(@as(i64, x.parent.size_left) + byte_delta);
            x.parent.lf_left = @intCast(@as(i64, x.parent.lf_left) + lf_delta);
        }
        x = x.parent;
    }
}

// Debug methods

fn subtreeBytes(self: *PieceTree, node: *Node) u32 {
    if (node == self.sentinel) return 0;
    return self.subtreeBytes(node.left) + node.piece.len + self.subtreeBytes(node.right);
}

fn subtreeLineFeeds(self: *PieceTree, node: *Node) u32 {
    if (node == self.sentinel) return 0;
    return self.subtreeLineFeeds(node.left) + node.piece.line_feeds + self.subtreeLineFeeds(node.right);
}

/// Assert the incrementally-maintained augmentation matches a from-scratch
/// recomputation for every node.
pub fn validate(self: *PieceTree, node: *Node) void {
    if (node == self.sentinel) return;
    std.debug.assert(node.size_left == self.subtreeBytes(node.left));
    std.debug.assert(node.lf_left == self.subtreeLineFeeds(node.left));
    self.validate(node.left);
    self.validate(node.right);
}

/// Result of locating a byte offset within the tree.
const Position = struct {
    node: *Node,
    remainder: u32, // byte offset of the target within node.piece
    node_start_offset: u32, // absolute byte offset where node.piece begins
};

pub const Node = struct {
    parent: *Node,
    left: *Node,
    right: *Node,

    color: Color,
    piece: Piece,

    size_left: u32,
    lf_left: u32,
};

const Color = enum(u1) { black = 0, red = 1 };

const BufferIndex = enum(u32) { change = 0, _ };
pub const DocumentOffset = enum(u32) { zero = 0, _ };
pub const BufferOffset = enum(u32) { _ };
pub const PieceOffset = enum(u32) { _ };

pub const Piece = struct {
    idx: BufferIndex,
    start: u32,
    len: u32,
    line_feeds: u32,
};

const Buffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Byte offset of the start of each line within this buffer.
    /// Always starts with 0; one entry appended immediately after every '\n'.
    /// Used to turn a byte offset into (line, column) by binary search.
    line_starts: std.ArrayList(u32) = .empty,

    fn deinit(self: *Buffer, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
        self.line_starts.deinit(alloc);
    }
};

test "load tree" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "Hello, world\n");
}
