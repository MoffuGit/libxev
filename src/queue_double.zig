const std = @import("std");

pub fn Intrusive(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head is the front of the queue and tail is the back of the queue.
        head: ?*T = null,
        tail: ?*T = null,

        /// Enqueue a new element to the back of the queue.
        /// The element's `next` and `prev` fields must be null.
        pub fn push(self: *Self, v: *T) void {
            std.debug.assert(v.next == null);
            std.debug.assert(v.prev == null);

            if (self.tail) |tail| {
                // If we have elements in the queue, then we add a new tail.
                tail.next = v;
                v.prev = tail;
                self.tail = v;
            } else {
                // No elements in the queue we setup the initial state.
                self.head = v;
                self.tail = v;
            }
        }

        /// Dequeue the next element from the queue.
        pub fn pop(self: *Self) ?*T {
            // The next element is in "head".
            const removed_elem = self.head orelse return null;

            // Update head to the next element
            self.head = removed_elem.next;
            if (self.head) |new_head| {
                new_head.prev = null;
            } else {
                // If the head became null, the list is now empty, so tail must also be null.
                self.tail = null;
            }

            // We set the "next" and "prev" fields to null so that this element
            // can be inserted again.
            removed_elem.next = null;
            removed_elem.prev = null;
            return removed_elem;
        }

        /// Removes a specific element `v` from the queue.
        /// The element `v` must currently be in the queue.
        pub fn remove(self: *Self, v: *T) void {
            if (v.prev) |prev_elem| {
                // Not the head
                prev_elem.next = v.next;
            } else {
                // Is the head
                self.head = v.next;
            }

            if (v.next) |next_elem| {
                // Not the tail
                next_elem.prev = v.prev;
            } else {
                // Is the tail
                self.tail = v.prev;
            }

            // If the element removed was the head, and it had no next element,
            // then the list is now empty.
            if (self.head == null) {
                self.tail = null;
            }

            // Clear the removed element's pointers
            v.next = null;
            v.prev = null;
        }

        /// Returns true if the queue is empty.
        pub fn empty(self: *const Self) bool {
            return self.head == null;
        }
    };
}

test Intrusive {
    const testing = std.testing;

    const Elem = struct {
        const Self = @This();
        value: usize,
        next: ?*Self = null,
        prev: ?*Self = null,
    };
    const Queue = Intrusive(Elem);
    var q: Queue = .{};
    try testing.expect(q.empty());

    var elems: [10]Elem = undefined;
    for (&elems, 0..) |*elem, i| {
        elem.value = i;
        elem.next = null;
        elem.prev = null;
    }

    // One
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(!q.empty());
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop() == null);
    try testing.expect(q.empty());

    // Two
    q.push(&elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);
    try testing.expect(q.empty());

    // Remove middle element
    q.push(&elems[0]); // value 0
    q.push(&elems[1]); // value 1
    q.push(&elems[2]); // value 2
    try testing.expect(q.head.? == &elems[0]);
    try testing.expect(q.tail.? == &elems[2]);
    try testing.expect(q.head.?.next.? == &elems[1]);
    try testing.expect(q.tail.?.prev.? == &elems[1]);

    q.remove(&elems[1]); // Remove element with value 1
    try testing.expect(q.head.? == &elems[0]);
    try testing.expect(q.tail.? == &elems[2]);
    try testing.expect(q.head.?.next.? == &elems[2]);
    try testing.expect(q.tail.?.prev.? == &elems[0]);
    try testing.expect(elems[1].next == null);
    try testing.expect(elems[1].prev == null);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[2]);
    try testing.expect(q.empty());

    // Remove head
    q.push(&elems[0]);
    q.push(&elems[1]);
    q.remove(&elems[0]);
    try testing.expect(q.head.? == &elems[1]);
    try testing.expect(q.tail.? == &elems[1]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.empty());

    // Remove tail
    q.push(&elems[0]);
    q.push(&elems[1]);
    q.remove(&elems[1]);
    try testing.expect(q.head.? == &elems[0]);
    try testing.expect(q.tail.? == &elems[0]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.empty());

    // Remove only element
    q.push(&elems[0]);
    q.remove(&elems[0]);
    try testing.expect(q.empty());
    try testing.expect(q.head == null);
    try testing.expect(q.tail == null);
}
