const std = @import("std");

pub fn Intrusive(comptime T: type) type {
    return struct {
        const Self = @This();
        buffer: []T,
        head: ?*T = null,

        pub fn init(buffer: []T) Self {
            var self: Self = .{ .buffer = buffer };

            if (buffer.len == 0) {
                return self;
            }

            var i: usize = 0;
            while (i < buffer.len) : (i += 1) {
                var t = &self.buffer[i];
                t.next = self.head;
                self.head = t;
            }
            return self;
        }

        pub fn alloc(self: *Self) !*T {
            if (self.head) |head| {
                self.head = head.next;
                head.next = null;
                return head;
            }
            return error.Exhausted;
        }

        pub fn free(self: *Self, t: *T) void {
            // Assuming T has a .next field
            t.next = self.head;
            self.head = t;
        }

        pub fn countFree(self: *const Self) usize {
            var count: usize = 0;
            var current = self.head;
            while (current) |t| {
                count += 1;
                current = t.next;
            }
            return count;
        }
    };
}

test "Pool functionality" {
    const Elem = struct {
        const Self = @This();

        next: ?*Self = null,
        data: usize,
    };
    const TestPool = Intrusive(Elem);

    var elem_buffer: [3]Elem = undefined;
    var pool = TestPool.init(&elem_buffer);

    try std.testing.expectEqual(pool.countFree(), 3);

    const node1 = try pool.alloc();
    node1.data = 100;
    try std.testing.expectEqual(pool.countFree(), 2);

    const node2 = try pool.alloc();
    node2.data = 200;
    try std.testing.expectEqual(pool.countFree(), 1);

    const node3 = try pool.alloc();
    node3.data = 300;
    try std.testing.expectEqual(pool.countFree(), 0);

    try std.testing.expectError(error.Exhausted, pool.alloc());

    pool.free(node2);
    try std.testing.expectEqual(pool.countFree(), 1);

    const node4 = try pool.alloc();
    try std.testing.expectEqual(node4, node2);
    try std.testing.expectEqual(pool.countFree(), 0);

    pool.free(node1);
    try std.testing.expectEqual(pool.countFree(), 1);
    pool.free(node3);
    try std.testing.expectEqual(pool.countFree(), 2);

    _ = try pool.alloc();
    _ = try pool.alloc();
    try std.testing.expectError(error.Exhausted, pool.alloc());
}
