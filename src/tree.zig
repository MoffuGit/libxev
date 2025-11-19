const std = @import("std");
const assert = std.debug.assert;

pub const Color = enum {
    Red,
    Black,
};

/// The state that is required for Intrusive Red-Black Tree element types.
/// This should be set as the "rb_node" field in the type T.
pub fn IntrusiveField(comptime T: type) type {
    return struct {
        color: Color = .Red,
        parent: ?*T = null,
        left: ?*T = null,
        right: ?*T = null,
    };
}

/// An intrusive Red-Black Tree implementation.
///
/// Usage notes:
/// - The element T is expected to have a field "rb_node" of type IntrusiveField.
/// - The `compare` function should return `std.math.Order` to indicate
///   ordering between two elements.
pub fn Intrusive(
    comptime T: type,
    comptime Context: type,
    comptime compare: *const fn (ctx: Context, a: *T, b: *T) std.math.Order,
) type {
    return struct {
        const Self = @This();

        root: ?*T = null,
        context: Context,

        /// Inserts a new element `v` into the tree.
        pub fn insert(self: *Self, v: *T) void {
            v.rb_node = .{}; // Initialize node as Red with no children/parent

            var current = self.root;
            var parent: ?*T = null;

            while (current) |node| {
                parent = node;
                switch (compare(self.context, v, node)) {
                    .lt => current = node.rb_node.left,
                    .gt => current = node.rb_node.right,
                    .eq => {
                        // Value already exists, or is considered equal.
                        // In a unique key tree, you might return early or assert.
                        // For now, we'll allow duplicates, but the comparison
                        // function might need to be more precise for "uniqueness".
                        // If it's truly an equal node, it might replace it or be a no-op.
                        // For simplicity, we'll treat it as a duplicate and do nothing for now.
                        // assert(false, "Inserting a duplicate value is not supported without a strategy.");
                        return;
                    },
                }
            }

            v.rb_node.parent = parent;
            if (parent == null) {
                self.root = v;
            } else {
                switch (compare(self.context, v, parent.?)) {
                    .lt => parent.?.rb_node.left = v,
                    .gt => parent.?.rb_node.right = v,
                    .eq => unreachable, // Handled above, or indicates a bug
                }
            }

            self.insert_fixup(v);
        }

        /// Finds an element `v` in the tree that compares equal to the provided `key`.
        /// Returns the found element or `null` if not found.
        pub fn find(self: *Self, key: *T) ?*T {
            var current = self.root;
            while (current) |node| {
                switch (compare(self.context, key, node)) {
                    .lt => current = node.rb_node.left,
                    .gt => current = node.rb_node.right,
                    .eq => return node,
                }
            }
            return null;
        }

        /// Returns the minimum element in the tree, or `null` if the tree is empty.
        pub fn findMin(self: *Self) ?*T {
            var current = self.root;
            if (current == null) return null;

            while (current.?.rb_node.left) |left_child| {
                current = left_child;
            }
            return current;
        }

        /// Returns the maximum element in the tree, or `null` if the tree is empty.
        pub fn findMax(self: *Self) ?*T {
            var current = self.root;
            if (current == null) return null;

            while (current.?.rb_node.right) |right_child| {
                current = right_child;
            }
            return current;
        }

        fn get_color(self: *Self, node: ?*T) Color {
            _ = self;
            return if (node) |n| n.rb_node.color else .Black;
        }

        fn set_color(self: *Self, node: *T, color: Color) void {
            _ = self;
            node.rb_node.color = color;
        }

        fn rotate_left(self: *Self, x: *T) void {
            const y = x.rb_node.right orelse return; // y cannot be null
            x.rb_node.right = y.rb_node.left;
            if (y.rb_node.left) |left_child| {
                left_child.rb_node.parent = x;
            }
            y.rb_node.parent = x.rb_node.parent;
            if (x.rb_node.parent == null) {
                self.root = y;
            } else if (x == x.rb_node.parent.?.rb_node.left) {
                x.rb_node.parent.?.rb_node.left = y;
            } else {
                x.rb_node.parent.?.rb_node.right = y;
            }
            y.rb_node.left = x;
            x.rb_node.parent = y;
        }

        fn rotate_right(self: *Self, x: *T) void {
            const y = x.rb_node.left orelse return; // y cannot be null
            x.rb_node.left = y.rb_node.right;
            if (y.rb_node.right) |right_child| {
                right_child.rb_node.parent = x;
            }
            y.rb_node.parent = x.rb_node.parent;
            if (x.rb_node.parent == null) {
                self.root = y;
            } else if (x == x.rb_node.parent.?.rb_node.right) {
                x.rb_node.parent.?.rb_node.right = y;
            } else {
                x.rb_node.parent.?.rb_node.left = y;
            }
            y.rb_node.right = x;
            x.rb_node.parent = y;
        }

        fn insert_fixup(self: *Self, z: *T) void {
            var current_z = z;
            while (self.get_color(current_z.rb_node.parent) == .Red) {
                const parent = current_z.rb_node.parent.?; // Parent is Red, so not null
                const grandparent = parent.rb_node.parent.?; // Parent is Red, so grandparent must exist

                if (parent == grandparent.rb_node.left) {
                    const uncle = grandparent.rb_node.right;
                    if (self.get_color(uncle) == .Red) {
                        // Case 1: Parent and uncle are Red
                        self.set_color(parent, .Black);
                        self.set_color(uncle.?, .Black);
                        self.set_color(grandparent, .Red);
                        current_z = grandparent;
                    } else {
                        // Case 2 & 3: Uncle is Black
                        if (current_z == parent.rb_node.right) {
                            // Case 2: Z is a right child
                            current_z = parent;
                            self.rotate_left(current_z);
                            // After rotation, `parent` is now `current_z`
                            // and `current_z`'s parent is the original `grandparent`.
                            // This effectively transforms Case 2 into Case 3.
                        }
                        // Case 3: Z is a left child (or was after case 2)
                        self.set_color(current_z.rb_node.parent.?, .Black); // Parent
                        self.set_color(current_z.rb_node.parent.?.rb_node.parent.?, .Red); // Grandparent
                        self.rotate_right(current_z.rb_node.parent.?.rb_node.parent.?); // Grandparent
                    }
                } else {
                    // Symmetric cases for when parent is the right child
                    const uncle = grandparent.rb_node.left;
                    if (self.get_color(uncle) == .Red) {
                        // Case 1: Parent and uncle are Red
                        self.set_color(parent, .Black);
                        self.set_color(uncle.?, .Black);
                        self.set_color(grandparent, .Red);
                        current_z = grandparent;
                    } else {
                        // Case 2 & 3: Uncle is Black
                        if (current_z == parent.rb_node.left) {
                            // Case 2: Z is a left child
                            current_z = parent;
                            self.rotate_right(current_z);
                        }
                        // Case 3: Z is a right child (or was after case 2)
                        self.set_color(current_z.rb_node.parent.?, .Black);
                        self.set_color(current_z.rb_node.parent.?.rb_node.parent.?, .Red);
                        self.rotate_left(current_z.rb_node.parent.?.rb_node.parent.?);
                    }
                }
            }
            self.set_color(self.root.?, .Black); // Root must always be Black
        }

        // Helper function for the iterator: finds the minimum element in a given subtree.
        // Assumes 'node' is not null.
        fn findMinInSubtree(node: *T) *T {
          var current = node;
          while (current.rb_node.left) |left_child| {
              current = left_child;
          }
          return current;
        }

        /// An iterator for the Red-Black Tree, providing in-order traversal.
        pub const Iterator = struct {
          current: ?*T,
          tree: *Self, // Reference to the Intrusive tree instance

          /// Initializes the iterator, starting at the smallest element in the tree.
          pub fn init(tree: *Self) @This() {
              return .{
                  .current = tree.findMin(), // Start at the smallest element
                  .tree = tree,
              };
          }

          /// Returns the current element and advances the iterator to the next in-order element.
          /// Returns `null` if the iterator is exhausted.
          pub fn next(self: *@This()) ?*T {
              const node_to_return = self.current;
              if (node_to_return == null) {
                  return null; // Iterator is exhausted
              }

              if (node_to_return.?.rb_node.right) |right_child| {
                  // Case 1: Node has a right child, successor is the minimum in the right subtree
                  self.current = self.tree.findMinInSubtree(right_child);
              } else {
                  // Case 2: Node has no right child, traverse up to find the successor
                  var child = node_to_return.?;
                  var parent = child.rb_node.parent;
                  while (parent) |p| {
                      if (child == p.rb_node.left) {
                          // Found the first ancestor for which 'child' is a left child
                          self.current = p;
                          break;
                      }
                      child = p;
                      parent = p.rb_node.parent;
                  }
                  if (parent == null) {
                      // Reached the root or beyond, no successor found (end of tree)
                      self.current = null;
                  }
              }
              return node_to_return;
          }
        };

        /// Returns a new iterator for the tree, starting at the minimum element.
        pub fn iterator(self: *Self) Iterator {
          return Iterator.init(self);
        }
    };
}

test "rb_tree_insert_and_find" {
    const testing = std.testing;

    const Elem = struct {
        const Self = @This();
        value: usize = 0,
        rb_node: IntrusiveField(Self) = .{},
    };

    const RbTree = Intrusive(Elem, void, (struct {
        fn compare(ctx: void, a: *Elem, b: *Elem) std.math.Order {
            _ = ctx;
            if (a.value < b.value) return .lt;
            if (a.value > b.value) return .gt;
            return .eq;
        }
    }).compare);

    var h: RbTree = .{ .context = {} };

    var a: Elem = .{ .value = 10 };
    var b: Elem = .{ .value = 20 };
    var c: Elem = .{ .value = 5 };
    var d: Elem = .{ .value = 15 };
    var e: Elem = .{ .value = 25 };

    h.insert(&a); // Root: 10 (Black)
    h.insert(&b); // 10(B) -> 20(R)
    h.insert(&c); // 10(B) -> 5(R), 20(R) -> recolor 10(R), 5(B), 20(B) -> rotate_right(10) -> 5(B) -> 10(R), 20(B)
                  // should be: 10(B) root. insert 20(R). insert 5(R).
                  // Parent(10) is Black.
                  // insert 5(R). parent 10(B).
                  // After 5(R) is inserted: Root 10(B), L:5(R), R:20(R)
                  // Now insert 15. parent 20(R), grandparent 10(B). uncle 5(R).
                  // Case 1: parent 20(R) and uncle 5(R) are Red.
                  // Recolor parent 20(B), uncle 5(B), grandparent 10(R). z = grandparent (10).
                  // Now current_z=10. Parent of 10 is null (root). Loop terminates.
                  // Root is set to Black.
                  // Tree: 10(B) -> L:5(B), R:20(B).  20(B) -> L:15(R)
    h.insert(&d);
    h.insert(&e);

    try testing.expect(h.find(&a).?.value == 10);
    try testing.expect(h.find(&b).?.value == 20);
    try testing.expect(h.find(&c).?.value == 5);
    try testing.expect(h.find(&d).?.value == 15);
    try testing.expect(h.find(&e).?.value == 25);

    // Test for non-existent value
    var f: Elem = .{ .value = 99 };
    try testing.expect(h.find(&f) == null);

    // Test min/max
    try testing.expect(h.findMin().?.value == 5);
    try testing.expect(h.findMax().?.value == 25);

    // Assert specific color properties after initial inserts
    // This is highly dependent on the insert sequence and fixups.
    // For this set of values (10, 20, 5, 15, 25), a possible final tree might be:
    //      15 (Black)
    //     /    \
    //   10(R)  20(R)
    //  /      /   \
    // 5(B)   null  25(B)

    // Verify root is black
    try testing.expect(h.root.?.rb_node.color == .Black);
    try testing.expect(h.root.?.value == 10); // Root might be 15, 10, or another value depending on rotations

    // Verify properties of children of the root (if present and not null)
    // This is illustrative and might need adjustment based on exact tree structure.
    const root_val = h.root.?.value;
    if (root_val == 15) {
        try testing.expect(h.root.?.rb_node.left.?.value == 10);
        try testing.expect(h.root.?.rb_node.left.?.rb_node.color == .Red);
        try testing.expect(h.root.?.rb_node.right.?.value == 20);
        try testing.expect(h.root.?.rb_node.right.?.rb_node.color == .Red);
    }
}
