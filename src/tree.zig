const std = @import("std");
const assert = std.debug.assert;

pub const Color = enum {
    Black,
    Red,
};

pub fn IntrusiveField(comptime T: type) type {
    return struct {
        color: Color = .Red,
        parent: ?*T = null,
        left: ?*T = null,
        right: ?*T = null,
    };
}

pub fn Intrusive(
    comptime T: type,
    comptime compare: *const fn (a: *T, b: *T) std.math.Order,
) type {
    return struct {
        const Self = @This();

        root: ?*T = null,

        pub fn insert(self: *Self, v: *T) void {
            v.rb_node = .{};

            var current = self.root;
            var parent: ?*T = null;

            while (current) |node| {
                parent = node;
                switch (compare(v, node)) {
                    .lt => current = node.rb_node.left,
                    .gt => current = node.rb_node.right,
                    .eq => {
                        return;
                    },
                }
            }

            v.rb_node.parent = parent;
            if (parent == null) {
                self.root = v;
            } else {
                switch (compare(v, parent.?)) {
                    .lt => parent.?.rb_node.left = v,
                    .gt => parent.?.rb_node.right = v,
                    .eq => unreachable,
                }
            }

            self.insert_fixup(v);
        }

        pub fn find(self: *Self, key: *T) ?*T {
            var current = self.root;
            while (current) |node| {
                switch (compare(key, node)) {
                    .lt => current = node.rb_node.left,
                    .gt => current = node.rb_node.right,
                    .eq => return node,
                }
            }
            return null;
        }

        pub fn findMin(self: *Self) ?*T {
            var current = self.root;
            if (current == null) return null;

            while (current.?.rb_node.left) |left_child| {
                current = left_child;
            }
            return current;
        }

        pub fn findMax(self: *Self) ?*T {
            var current = self.root;
            if (current == null) return null;

            while (current.?.rb_node.right) |right_child| {
                current = right_child;
            }
            return current;
        }

        fn get_color(_: *Self, node: ?*T) Color {
            return if (node) |n| n.rb_node.color else .Black;
        }

        fn set_color(_: *Self, node: *T, color: Color) void {
            node.rb_node.color = color;
        }

        fn rotate_left(self: *Self, x: *T) void {
            const y = x.rb_node.right orelse return;
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
            const y = x.rb_node.left orelse return;
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
                const parent = current_z.rb_node.parent.?;
                const grandparent = parent.rb_node.parent.?;

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
            self.set_color(self.root.?, .Black);
        }

        fn tree_minimum(_: *Self, node: *T) *T {
            var current = node;
            while (current.rb_node.left) |left_child| {
                current = left_child;
            }
            return current;
        }

        fn transplant(self: *Self, u: *T, v: ?*T) void {
            if (u.rb_node.parent == null) {
                self.root = v;
            } else if (u == u.rb_node.parent.?.rb_node.left) {
                u.rb_node.parent.?.rb_node.left = v;
            } else {
                u.rb_node.parent.?.rb_node.right = v;
            }
            if (v) |val_v| {
                val_v.rb_node.parent = u.rb_node.parent;
            }
        }

        fn delete_fixup(self: *Self, x: ?*T, x_parent: *T) void {
            var current_x = x;
            var current_x_parent: *T = x_parent;

            while (current_x != self.root and self.get_color(current_x) == .Black) {
                if (current_x == current_x_parent.rb_node.left) {
                    var w = current_x_parent.rb_node.right.?;

                    if (self.get_color(w) == .Red) {
                        // Case 1: Sibling w is Red
                        self.set_color(w, .Black);
                        self.set_color(current_x_parent, .Red);
                        self.rotate_left(current_x_parent);
                        w = current_x_parent.rb_node.right.?;
                    }
                    // Sibling w is Black (or was made Black by Case 1)
                    if (self.get_color(w.rb_node.left) == .Black and self.get_color(w.rb_node.right) == .Black) {
                        // Case 2: Sibling w is Black and both its children are Black
                        self.set_color(w, .Red);
                        current_x = current_x_parent; // Move up the tree
                        current_x_parent = current_x.?.rb_node.parent orelse break;
                    } else {
                        if (self.get_color(w.rb_node.right) == .Black) {
                            // Case 3: Sibling w is Black, w's left child is Red, w's right child is Black
                            self.set_color(w.rb_node.left.?, .Black);
                            self.set_color(w, .Red);
                            self.rotate_right(w);
                            w = current_x_parent.rb_node.right.?; // Update w after rotation, transforming to Case 4
                        }
                        // Case 4: Sibling w is Black, w's right child is Red
                        self.set_color(w, self.get_color(current_x_parent));
                        self.set_color(current_x_parent, .Black);
                        self.set_color(w.rb_node.right.?, .Black);
                        self.rotate_left(current_x_parent);
                        current_x = self.root; // Terminate loop (rb-tree properties restored)
                    }
                } else { // Symmetric case: x is a right child
                    var w = current_x_parent.rb_node.left.?;

                    if (self.get_color(w) == .Red) {
                        // Case 1: Sibling w is Red
                        self.set_color(w, .Black);
                        self.set_color(current_x_parent, .Red);
                        self.rotate_right(current_x_parent);
                        w = current_x_parent.rb_node.left.?;
                    }
                    // Sibling w is Black
                    if (self.get_color(w.rb_node.right) == .Black and self.get_color(w.rb_node.left) == .Black) {
                        // Case 2: Sibling w is Black and both its children are Black
                        self.set_color(w, .Red);
                        current_x = current_x_parent; // Move up the tree
                        current_x_parent = current_x.?.rb_node.parent orelse break;
                    } else {
                        if (self.get_color(w.rb_node.left) == .Black) {
                            // Case 3: Sibling w is Black, w's right child is Red, w's left child is Black
                            self.set_color(w.rb_node.right.?, .Black);
                            self.set_color(w, .Red);
                            self.rotate_left(w);
                            w = current_x_parent.rb_node.left.?; // Update w after rotation, transforming to Case 4
                        }
                        // Case 4: Sibling w is Black, w's left child is Red
                        self.set_color(w, self.get_color(current_x_parent));
                        self.set_color(current_x_parent, .Black);
                        self.set_color(w.rb_node.left.?, .Black);
                        self.rotate_right(current_x_parent);
                        current_x = self.root;
                    }
                }
            }
            if (current_x) |val_x| {
                self.set_color(val_x, .Black);
            }
        }

        /// Removes an element `key` from the tree and returns the removed element, or `null` if not found.
        pub fn remove(self: *Self, key: *T) ?*T {
            const z = self.find(key) orelse return null;

            var y = z;
            var y_original_color = self.get_color(y);
            var x: ?*T = null;
            var x_parent_for_fixup: *T = undefined;

            if (z.rb_node.left == null) {
                // Case 1: z has no left child (or no children)
                x = z.rb_node.right;
                // z is replaced by its right child.
                // The node that was z's parent will become x's parent.
                // x_parent_for_fixup must refer to the node that becomes x's parent after transplant.
                // If x is null, its parent is the node that was z's parent.
                // If x is not null, its parent is also the node that was z's parent.
                x_parent_for_fixup = z.rb_node.parent orelse z;
                self.transplant(z, z.rb_node.right);
            } else if (z.rb_node.right == null) {
                // Case 2: z has no right child
                x = z.rb_node.left;
                x_parent_for_fixup = z.rb_node.parent orelse z;
                self.transplant(z, z.rb_node.left);
            } else {
                // Case 3: z has two children
                y = self.tree_minimum(z.rb_node.right.?);
                y_original_color = self.get_color(y);
                x = y.rb_node.right;
                x_parent_for_fixup = y;

                if (y.rb_node.parent != z) {
                    // If y is not a direct child of z, y's original position needs to be handled
                    // x_parent_for_fixup will be y's actual parent
                    x_parent_for_fixup = y.rb_node.parent.?;
                    self.transplant(y, y.rb_node.right);
                    y.rb_node.right = z.rb_node.right;
                    y.rb_node.right.?.rb_node.parent = y;
                }
                // If y.rb_node.parent == z, then y is z's direct right child.
                // In this case, x_parent_for_fixup remains y, and x will take y's place.
                // After transplanting z with y, y becomes z's replacement, and x's parent would be y.

                self.transplant(z, y);
                y.rb_node.left = z.rb_node.left;
                y.rb_node.left.?.rb_node.parent = y;
                self.set_color(y, self.get_color(z));
            }

            // Only call fixup if a black node was removed (or replaced by a null black node)
            if (y_original_color == .Black) {
                // If x is null and x_parent_for_fixup is z, this means z was the root and had one child.
                // x_parent_for_fixup should be the parent of the *position* x fills.
                // The `x_parent_for_fixup` logic in `delete_fixup` needs `*T` non-null.
                // If `x` is `self.root` after removal (meaning the tree became empty or `x` is the new root),
                // the fixup loop won't run. So `x_parent_for_fixup` is only really used if `x` is not the root.
                if (x != self.root) { // The fixup is not needed if x became the new root.
                    self.delete_fixup(x, x_parent_for_fixup);
                } else if (self.root != null) { // If x is root (non-null), make sure it's black.
                    self.set_color(self.root.?, .Black);
                }
            }
            return z; // Return the removed node
        }
        pub fn replace(self: *Self, old: *T, new: *T) !void {
            if (T.compare(old, new) != .eq) {
                return error.NotEqual;
            }
            assert(new.rb_node.parent == null);
            assert(new.rb_node.left == null);
            assert(new.rb_node.right == null);

            new.rb_node = old.rb_node;

            if (old.rb_node.parent) |parent| {
                if (parent.rb_node.left == old) {
                    parent.rb_node.left = new;
                } else {
                    parent.rb_node.right = new;
                }
            } else {
                self.root = new;
            }

            if (old.rb_node.left) |left_child| {
                left_child.rb_node.parent = new;
            }
            if (old.rb_node.right) |right_child| {
                right_child.rb_node.parent = new;
            }

            old.rb_node = .{};
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

    const RbTree = Intrusive(Elem, (struct {
        fn compare(a: *Elem, b: *Elem) std.math.Order {
            if (a.value < b.value) return .lt;
            if (a.value > b.value) return .gt;
            return .eq;
        }
    }).compare);

    var h: RbTree = .{};

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

test "rb_tree_remove" {
    const testing = std.testing;

    const Elem = struct {
        const Self = @This();
        value: usize = 0,
        rb_node: IntrusiveField(Self) = .{},
    };

    const RbTree = Intrusive(Elem, (struct {
        fn compare(a: *Elem, b: *Elem) std.math.Order {
            if (a.value < b.value) return .lt;
            if (a.value > b.value) return .gt;
            return .eq;
        }
    }).compare);

    var h: RbTree = .{};

    // Prepare elements for insertion and deletion
    var elems: [10]Elem = .{
        .{ .value = 10 }, .{ .value = 20 }, .{ .value = 5 }, .{ .value = 15 }, .{ .value = 25 },
        .{ .value = 30 }, .{ .value = 2 },  .{ .value = 7 }, .{ .value = 12 }, .{ .value = 17 },
    };

    // Insert all elements
    for (&elems) |*e| {
        h.insert(e);
    }

    // Verify initial state
    try testing.expect(h.find(&elems[0]).?.value == 10); // 10
    try testing.expect(h.find(&elems[6]).?.value == 2); // 2
    try testing.expect(h.findMin().?.value == 2);
    try testing.expect(h.findMax().?.value == 30);

    // Test removing a non-existent element
    var non_existent: Elem = .{ .value = 99 };
    try testing.expect(h.remove(&non_existent) == null);
    try testing.expect(h.findMin().?.value == 2); // Still 2
    try testing.expect(h.findMax().?.value == 30); // Still 30

    // Remove a leaf node (e.g., 2)
    const removed_2 = h.remove(&elems[6]) orelse unreachable; // elems[6] is 2
    try testing.expect(removed_2.value == 2);
    try testing.expect(h.find(&elems[6]) == null); // Should not be found
    try testing.expect(h.findMin().?.value == 5); // New min is 5

    // Remove a node with one child (e.g., 7, assuming 5 is its parent and 10 is its right child)
    // The exact structure depends on rotations, but 7 might have 5 as parent and 10 as grandparent.
    // Let's remove 7 (elems[7])
    const removed_7 = h.remove(&elems[7]) orelse unreachable; // elems[7] is 7
    try testing.expect(removed_7.value == 7);
    try testing.expect(h.find(&elems[7]) == null);
    try testing.expect(h.findMin().?.value == 5); // Still 5

    // Remove a node with two children (e.g., 10)
    // The tree should still contain 5, 12, 15, 17, 20, 25, 30
    const removed_10 = h.remove(&elems[0]) orelse unreachable; // elems[0] is 10
    try testing.expect(removed_10.value == 10);
    try testing.expect(h.find(&elems[0]) == null);
    try testing.expect(h.findMin().?.value == 5);

    // After removing 10, 12 should be in the tree
    try testing.expect(h.find(&elems[8]).?.value == 12); // elems[8] is 12

    // Remove remaining elements and check state
    _ = h.remove(&elems[2]); // 5
    _ = h.remove(&elems[8]); // 12
    _ = h.remove(&elems[3]); // 15
    _ = h.remove(&elems[9]); // 17
    _ = h.remove(&elems[1]); // 20
    _ = h.remove(&elems[4]); // 25
    _ = h.remove(&elems[5]); // 30

    try testing.expect(h.root == null); // Tree should be empty
    try testing.expect(h.findMin() == null);
    try testing.expect(h.findMax() == null);

    // Re-insert some elements to test an empty tree after deletions
    var re_elem1: Elem = .{ .value = 100 };
    var re_elem2: Elem = .{ .value = 50 };
    h.insert(&re_elem1);
    h.insert(&re_elem2);

    try testing.expect(h.root.?.value == 100); // Or 50, depends on fixup
    try testing.expect(h.get_color(h.root.?) == .Black);
    try testing.expect(h.findMin().?.value == 50);
    try testing.expect(h.findMax().?.value == 100);

    _ = h.remove(&re_elem1);
    try testing.expect(h.root.?.value == 50);
    _ = h.remove(&re_elem2);
    try testing.expect(h.root == null);
}
