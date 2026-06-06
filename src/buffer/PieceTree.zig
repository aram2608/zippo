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

/// Resolve the bytes in a buffer given a specific index
fn bufferBytes(self: *const PieceTree, idx: BufferIndex) []const u8 {
    return self.buffers.items[@intFromEnum(idx)].bytes.items;
}

/// A simple helper to calculate the line feeds in a slice of bytes
fn countLF(bytes: []const u8, start: u32, end: u32) u32 {
    var n: u32 = 0;
    for (bytes[start..end]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
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

    self.last_change_pos = start + @as(u32, @intCast(text.len));

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

fn classify(self: *const PieceTree, p: Position, o: u32) InsertInst {
    const piece = p.node.piece;
    if (piece.idx == .change and piece.start + piece.len == self.last_change_pos and p.node_start_offset + piece.len == o) return .hot_path;
    if (p.node_start_offset == o) return .node_boundary;
    if (p.node_start_offset + piece.len > o) return .mid_node;
    return .end_node;
}

pub fn insert(self: *PieceTree, offset: u32, text: []const u8) !void {
    // Graft brand new nodes
    if (self.root == self.sentinel) {
        const np = try self.appendToChangeBuffer(text);
        _ = try self.insertLeft(null, np);
        return;
    }

    const pos = self.nodeAt(offset).?;
    const inst: InsertInst = self.classify(pos, offset);

    const np = try self.appendToChangeBuffer(text);
    switch (inst) {
        // Hot-Path for typing, we simply bump the node length given the length
        // of the input text
        // The char is input from the last touched piece so we do not have to
        // make a new one
        .hot_path => {
            pos.node.piece.len += np.len;
            pos.node.piece.line_feeds += np.line_feeds;
            self.updateMetadata(pos.node, np.len, np.line_feeds);
        },
        .node_boundary => {
            _ = try self.insertLeft(pos.node, np);
        },
        // Mid node split, you have one piece [A | B] and want [A | NEW | B].
        .mid_node => {
            const old = pos.node.piece;
            // Offset in the buffer at the split
            const split_at = old.start + pos.remainder;

            // The new right piece is constructed from the
            // old index and the split location
            // The length is adjusted by the remaining length
            const right_piece: Piece = .{
                .idx = old.idx,
                .start = split_at,
                .len = old.len - pos.remainder,
                .line_feeds = countLF(self.bufferBytes(old.idx), split_at, old.start + old.len),
            };

            // The existing node needs to shrink down
            const new_left_lf = old.line_feeds - right_piece.line_feeds;
            const len_delta = -@as(i64, right_piece.len);
            const lf_delta = -@as(i64, right_piece.line_feeds);
            pos.node.piece.len = pos.remainder;
            pos.node.piece.line_feeds = new_left_lf;
            self.updateMetadata(pos.node, len_delta, lf_delta);

            // The new piece is grafted to B as successive right-insertions
            const mid = try self.insertRight(pos.node, np);
            _ = try self.insertRight(mid, right_piece);
        },
        .end_node => {
            _ = try self.insertRight(pos.node, np);
        },
    }
}

/// Trim the first `remainder` bytes off the piece's left side.
fn deleteNodeHead(self: *PieceTree, node: *Node, remainder: u32) void {
    const old = node.piece;
    const dropped_lf = countLF(self.bufferBytes(old.idx), old.start, old.start + remainder);

    node.piece.start = old.start + remainder;
    node.piece.len = old.len - remainder;
    node.piece.line_feeds = old.line_feeds - dropped_lf;
    self.updateMetadata(node, -@as(i64, remainder), -@as(i64, dropped_lf));
}

/// Keep only the first `remainder` bytes of the piece.
fn deleteNodeTail(self: *PieceTree, node: *Node, remainder: u32) void {
    const old = node.piece;
    const kept_lf = countLF(self.bufferBytes(old.idx), old.start, old.start + remainder);
    const dropped_len = old.len - remainder;

    node.piece.len = remainder;
    node.piece.line_feeds = kept_lf;
    self.updateMetadata(node, -@as(i64, dropped_len), -@as(i64, old.line_feeds - kept_lf));
}

/// Split `node` into [0..start) and [end..len), drop the middle.
fn shrinkNode(self: *PieceTree, node: *Node, start: u32, end: u32) !void {
    const old = node.piece;
    const right_start = old.start + end;
    const right_len = old.len - end;
    const right_lf = countLF(self.bufferBytes(old.idx), right_start, right_start + right_len);

    self.deleteNodeTail(node, start);
    _ = try self.insertRight(node, .{
        .idx = old.idx,
        .start = right_start,
        .len = right_len,
        .line_feeds = right_lf,
    });
}

fn recomputeMetaData(self: *PieceTree, n: *Node) void {
    var x = n;
    var delta: u32 = 0;
    var lf_delta: u32 = 0;

    if (x == self.root) return;

    while (x != self.root and x == x.parent.right) {
        x = x.parent;
    }

    if (x == self.root) return;

    x = x.parent;

    const new_sl = self.calcSize(x.left);
    const new_lfl = self.calcLF(x.left);
    delta = new_sl - x.size_left;
    lf_delta = new_lfl - x.lf_left;

    x.size_left = new_sl;
    x.lf_left = new_lfl;

    while (x != self.root) {
        if (x.parent.left == x) {
            x.parent.size_left += delta;
            x.parent.lf_left += lf_delta;
        }

        x = x.parent;
    }
}

fn calcLF(self: *const PieceTree, n: *Node) u32 {
    if (n == self.sentinel) return 0;
    return n.lf_left + n.piece.line_feeds + self.calcLF(n.right);
}

fn calcSize(self: *const PieceTree, n: *Node) u32 {
    if (n == self.sentinel) return 0;
    return n.size_left + n.piece.len + self.calcSize(n.right);
}

pub fn delete(self: *PieceTree, offset: u32, count: u32) !void {
    if (count == 0 or self.root == self.sentinel) return;

    const start_pos = self.nodeAt(offset).?;
    const end_pos = self.nodeAt(offset + count).?;

    const start_node = start_pos.node;
    const end_node = end_pos.node;

    if (start_node == end_node) {
        if (start_pos.node_start_offset == offset) {
            if (count == start_node.piece.len) {
                self.deleteNode(start_node);
                return;
            }
            self.deleteNodeHead(start_node, end_pos.remainder);
            return;
        }

        if (start_pos.node_start_offset + start_node.piece.len == offset + count) {
            self.deleteNodeTail(start_node, start_pos.remainder);
            return;
        }

        try self.shrinkNode(start_node, start_pos.remainder, end_pos.remainder);
        return;
    }

    self.deleteNodeTail(start_node, start_pos.remainder);
    var n = self.successor(start_node);
    if (start_node.piece.len == 0) self.deleteNode(start_node);

    self.deleteNodeHead(end_node, end_pos.remainder);
    if (end_node.piece.len == 0) self.deleteNode(end_node);

    while (n != self.sentinel and n != end_node) {
        const after = self.successor(n);
        self.deleteNode(n);
        n = after;
    }
}

fn deleteNode(self: *PieceTree, z: *Node) void {
    var x: *Node = undefined;
    var y: *Node = undefined;

    if (z.left == self.sentinel) {
        y = z;
        x = y.right;
    } else if (z.right == self.sentinel) {
        y = z;
        x = y.left;
    } else {
        y = self.leftmost(z.right);
        x = y.right;
    }

    if (y == self.root) {
        self.root = x;
        x.color = .black;
        self.detach(z);
        self.root.parent = self.sentinel;
        return;
    }

    const y_was_red = y.color == .red;

    if (y == y.parent.left) {
        y.parent.left = x;
    } else {
        y.parent.right = x;
    }

    if (y == z) {
        x.parent = y.parent;
        self.recomputeMetaData(x);
    } else {
        if (y.parent == z) {
            x.parent = y;
        } else {
            x.parent = y.parent;
        }

        y.left = z.left;
        y.right = z.right;
        y.parent = z.parent;
        y.color = z.color;

        if (z == self.root) {
            self.root = y;
        } else {
            if (z == z.parent.left) {
                z.parent.left = y;
            } else {
                z.parent.right = y;
            }
        }

        if (y.left != self.sentinel) {
            y.left.parent = y;
        }

        if (y.right != self.sentinel) {
            y.right.parent = y;
        }
        y.size_left = x.size_left;
        y.lf_left = x.lf_left;
        self.recomputeMetaData(x);
    }

    self.detach(z);

    self.recomputeMetaData(x.parent);

    if (!y_was_red) self.fixDelete(x);
}

fn fixDelete(self: *PieceTree, x_param: *Node) void {
    var x = x_param;
    var w = x;
    while (x != self.root and x.color == .black) {
        if (x == x.parent.left) {
            w = x.parent.right;

            if (w.color == .red) {
                w.color = .black;
                x.parent.color = .red;
                self.leftRotate(x.parent);
                w = x.parent.left;
            }

            if (w.left.color == .black and w.right.color == .black) {
                w.color = .red;
                x = x.parent;
            } else {
                if (w.right.color == .black) {
                    w.left.color = .black;
                    w.color = .red;
                    self.rightRotate(x.parent);
                    x = self.root;
                }

                w.color = x.parent.color;
                x.parent.color = .black;
                x.right.color = .black;
                self.leftRotate(x.parent);
                x = self.root;
            }
        } else {
            w = x.parent.left;

            if (w.color == .red) {
                w.color = .black;
                x.parent.color = .red;
                self.rightRotate(x.parent);
                w = x.parent.left;
            }

            if (w.left.color == .black and w.right.color == .black) {
                w.color = .red;
                x = x.parent;
            } else {
                if (w.left.color == .black) {
                    w.right.color = .black;
                    w.color = .red;
                    self.leftRotate(w);
                    w = x.parent.left;
                }

                w.color = x.parent.color;
                x.parent.color = .black;
                w.left.color = .black;
                self.rightRotate(x.parent);
                x = self.root;
            }
        }
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

    self.updateMetadata(z, p.len, p.line_feeds);
    self.fixInsert(z);

    return z;
}

fn insertRight(self: *PieceTree, node: ?*Node, p: Piece) !*Node {
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
    } else if (node.?.right == self.sentinel) {
        node.?.right = z;
        z.parent = node.?;
    } else {
        var ln = self.leftmost(node.?.right);
        ln.left = z;
        z.parent = ln;
    }

    self.updateMetadata(z, p.len, p.line_feeds);
    self.fixInsert(z);
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

// I should probably just destroy the node since i have no garbage collector like JS
fn detach(self: *PieceTree, n: *Node) void {
    n.left = self.sentinel;
    n.right = self.sentinel;
    n.parent = self.sentinel;
    self.allocator.destroy(n);
}

fn successor(self: *const PieceTree, n: *Node) *Node {
    if (n.right != self.sentinel) return self.leftmost(n.right);
    var x = n;
    while (x.parent != self.sentinel and x == x.parent.right) x = x.parent;
    return x.parent;
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

const LineLoc = struct { node: *Node, offset_in_piece: u32 };

// Mirror of nodeAt, used for line locations
fn lineStart(self: *PieceTree, line: u32) ?LineLoc {
    if (line == 1) {
        // first byte of the leftmost piece
        if (self.root == self.sentinel) return null;
        return .{ .node = self.leftmost(self.root), .offset_in_piece = 0 };
    }
    var x = self.root;
    var lfs_needed: u32 = line - 1;
    while (x != self.sentinel) {
        if (x.lf_left >= lfs_needed) {
            x = x.left;
        } else if (x.lf_left + x.piece.line_feeds >= lfs_needed) {
            const lf_in_piece = lfs_needed - x.lf_left;
            return .{
                .node = x,
                .offset_in_piece = self.offsetAfterNthLF(x.piece, lf_in_piece),
            };
        } else {
            lfs_needed -= x.lf_left + x.piece.line_feeds;
            x = x.right;
        }
    }
    return null; // line past EOF
}

pub fn getLineContent(
    self: *PieceTree,
    allocator: std.mem.Allocator,
    line: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const loc = self.lineStart(line) orelse return out.toOwnedSlice(allocator);
    var node = loc.node;
    var off = loc.offset_in_piece;

    while (node != self.sentinel) {
        const p = node.piece;
        const bytes = self.bufferBytes(p.idx)[p.start + off .. p.start + p.len];
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |i| {
            try out.appendSlice(allocator, bytes[0..i]); // exclude the '\n'
            return out.toOwnedSlice(allocator);
        }
        try out.appendSlice(allocator, bytes);
        node = self.successor(node);
        off = 0;
    }
    return out.toOwnedSlice(allocator);
}

/// Document byte offset of the first byte of `line` (1-indexed).
/// Mirror of `lineStart`, but returns a flat offset instead of (node, in-piece).
pub fn offsetOfLine(self: *PieceTree, line: u32) ?u32 {
    if (line == 1) return 0;
    var x = self.root;
    var lfs_needed: u32 = line - 1;
    var off: u32 = 0;
    while (x != self.sentinel) {
        if (x.lf_left >= lfs_needed) {
            x = x.left;
        } else if (x.lf_left + x.piece.line_feeds >= lfs_needed) {
            const lf_in_piece = lfs_needed - x.lf_left;
            const in_piece = self.offsetAfterNthLF(x.piece, lf_in_piece);
            return off + x.size_left + in_piece;
        } else {
            off += x.size_left + x.piece.len;
            lfs_needed -= x.lf_left + x.piece.line_feeds;
            x = x.right;
        }
    }
    return null;
}

/// Helper method to use in the upperBound algorithm
/// std.math.order returns an enum with the two values comparisons
fn cmpU32(ctx: u32, item: u32) std.math.Order {
    return std.math.order(ctx, item);
}

/// Calculates the offset from a given line feed (LR)
/// std.sort.upperBound is a binary search function that returns the insertion
/// point at which the order is not violated
///
/// target value = 4;
/// list = [1, 3, 4, 5, 6]
///                  ^ return idx
fn offsetAfterNthLF(self: *PieceTree, p: Piece, k: u32) u32 {
    const ls = self.buffers.items[@intFromEnum(p.idx)].line_starts.items;
    const first = std.sort.upperBound(u32, ls, p.start, cmpU32);
    const abs = ls[first + k - 1];
    return abs - p.start;
}

/// Calculates the number of lines from the total line feeds (LR)
pub fn totalLines(self: *const PieceTree) u32 {
    if (self.root == self.sentinel) return 0;
    return self.subtreeLineFeeds(self.root) + 1;
}

/// Helper method to subset the bytes from a given node
fn subtreeBytes(self: *const PieceTree, node: *Node) u32 {
    if (node == self.sentinel) return 0;
    return self.subtreeBytes(node.left) + node.piece.len + self.subtreeBytes(node.right);
}

/// Helper method to calculate the line feeds from a given node
fn subtreeLineFeeds(self: *const PieceTree, node: *Node) u32 {
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

const InsertInst = enum {
    hot_path,
    mid_node,
    node_boundary,
    end_node,
};

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

test "insert into empty tree" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "hello");
    try std.testing.expectEqual(@as(u32, 5), p.root.piece.len);
    try std.testing.expect(p.root.color == .black);
    p.validate(p.root);
}

test "hot-path append extends piece" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "hel");
    try p.insert(3, "lo"); // should hit fast-append
    try std.testing.expectEqual(@as(u32, 5), p.root.piece.len);
    p.validate(p.root);
}

test "three sequential non-hot-path inserts trigger rotation" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "a");
    try p.insert(0, "b"); // node_boundary at offset 0
    try p.insert(0, "c"); // node_boundary again,should force rotation
    p.validate(p.root);
}

test "mid-node split" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "helloworld"); // one piece: len=10
    try p.insert(5, "_"); // split between "hello" and "world"
    // Tree should now span 11 bytes total
    try std.testing.expectEqual(@as(u32, 11), p.subtreeBytes(p.root));
    p.validate(p.root);
}

test "get line content" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "hello\nworld");
    const world = try p.getLineContent(std.testing.allocator, 2);
    try std.testing.expectEqualSlices(u8, "world", world);
    std.testing.allocator.free(world);
}

test "totalLines and offsetOfLine" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "ab\ncd\nef");
    try std.testing.expectEqual(@as(u32, 3), p.totalLines());
    try std.testing.expectEqual(@as(?u32, 0), p.offsetOfLine(1));
    try std.testing.expectEqual(@as(?u32, 3), p.offsetOfLine(2));
    try std.testing.expectEqual(@as(?u32, 6), p.offsetOfLine(3));
}

test "delete shrinks the middle of a single piece" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "helloXXXworld");
    try p.delete(5, 3); // drop "XXX" → "helloworld"
    try std.testing.expectEqual(@as(u32, 10), p.subtreeBytes(p.root));
    const line = try p.getLineContent(std.testing.allocator, 1);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualSlices(u8, "helloworld", line);
    p.validate(p.root);
}

test "delete spanning two pieces trims tail of first and head of second" {
    var p = try PieceTree.init(std.testing.allocator);
    defer p.deinit();
    try p.insert(0, "abcXX"); // right piece
    try p.insert(0, "YYdef"); // becomes left piece → doc is "YYdefabcXX"
    try p.delete(3, 4); // drop "efab" → "YYdcXX"
    try std.testing.expectEqual(@as(u32, 6), p.subtreeBytes(p.root));
    const line = try p.getLineContent(std.testing.allocator, 1);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualSlices(u8, "YYdcXX", line);
    p.validate(p.root);
}
