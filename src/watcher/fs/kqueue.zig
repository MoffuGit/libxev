const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const double = @import("../../queue_double.zig");
const tree = @import("../../tree.zig");
const pool = @import("../../pool.zig");
const fspkg = @import("../fs.zig");
const Callback = fspkg.Callback(@This());
const CallbackAction = fspkg.CallbackAction;
const CompletionState = fspkg.CompletionState;
const NoopCallback = fspkg.NoopCallback(@This());
const log = std.log.scoped(.fs);


const CAPACITY = 100;
const BASIS: u32 = 0x811c9dc5;
const PRIME: u32 = 0x1000193;

fn hash(bytes: []const u8) u32 {
    var h = BASIS;

    for (bytes) |byte| {
        h = h ^ @as(u32, byte);
        h = h *% PRIME;
    }
    return h;
}

pub fn FileSystem(comptime xev: type) type {
    const WatcherPool = pool.Intrusive(FileWatcher(xev));


    return struct {
        fn compare(a: *FileWatcher(xev), b: *FileWatcher(xev)) std.math.Order {
            if (a.hash > b.hash) return .gt;
            if (a.hash < b.hash) return .lt;
            return .eq;
        }

        buffer: [CAPACITY]FileWatcher(xev) = undefined,

        pool: WatcherPool = undefined,
        tree: tree.Intrusive(FileWatcher(xev), compare) = .{},
        flags: packed struct {
            init: bool =false,
        } = .{},

        const Self = @This();

        pub fn init() !Self {
            return .{};
        }

        pub fn start(self: *Self) void {
            if (self.flags.init) {
                return;
            }
                self.pool = WatcherPool.init(&self.buffer);
            self.flags.init = true;
        }

        pub fn deinit(self: *Self) void {
            if (!self.flags.init) {
                return;
            }

            //WARN:
            //i need to cancel and close every fd
            // var curr = self.pool.head;
            // while(curr) |w| {
            //     posix.close(w.fd);
            //     curr = w.next;
            // }
        }

        pub fn watch(self: *Self, loop: *xev.Loop, path: []const u8, c: *Completion) !void {
            self.start();

            var temp: FileWatcher(xev) = .{.hash = hash(path)};
            if(self.tree.find(&temp))|w| {
                w.completions.push(c);
            }else {
                var w = try self.pool.alloc();
                w.fd = try posix.open(path, posix.O{}, 0);
                w.hash = temp.hash;

                w.c = .{
                    .op = .{
                        .vnode = .{
                            .fd = w.fd,
                            // Flags for various file system changes
                            .flags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.ATTRIB | std.c.NOTE.EXTEND | std.c.NOTE.LINK | std.c.NOTE.RENAME,
                        },
                    },
                    .userdata = w,
                    .callback = vnode_callback,
                };
                 loop.add(&w.c); // Add the kqueue vnode event to the main loop

                self.tree.insert(w); // Add the FileWatcher to our tree
                w.completions.push(c);
            }

            c.hash = temp.hash;
            c.flags.state = .active;
        }

        pub fn cancel(self: *Self, c: *Completion) void {
            var temp_wd = FileWatcher(xev) { .hash = c.hash };

            if (self.tree.find(&temp_wd)) |watcher| {
                watcher.completions.remove(c);

                c.*.flags.state = .dead;

                if (watcher.completions.empty()) {
                    _ = self.tree.remove(watcher);
                    self.pool.free(watcher);
                    //NOTE:
                    //i would need to cancel the completion from the loop
                }
            }
        }

        fn vnode_callback(
            ud: ?*anyopaque,
            _: *xev.Loop,
            _: *xev.Completion, // The xev.Completion for this vnode watcher
            result: xev.Result,
        ) xev.CallbackAction {
            const watcher: *FileWatcher(xev) = @ptrCast(@alignCast(ud.?));
            const vnode_flags = result.vnode catch |err| {
                log.err("Vnode event error for fd {}: {any}", .{watcher.fd, err});
                // If there's an error on the vnode watcher itself, disarm it.
                // All user completions for this watcher will effectively stop receiving events.
                return .disarm;
            };

            // Temporarily move completions out to process them.
            // This allows safe modification of the completions queue during iteration.
            var temp_queue = watcher.completions;
            watcher.completions = .{};

            var current = temp_queue.pop();
            while (current) |comp| {
                const action = comp.invoke(vnode_flags);
                switch (action) {
                    .disarm => {
                        comp.flags.state = .dead;
                    },
                    .rearm => {
                        watcher.completions.push(comp);
                    },
                }
                current = temp_queue.pop();
            }

            return .rearm;
        }

        test {
            _ = FileSystemTest(xev);
        }
    };
}

pub fn FileWatcher(comptime xev: type) type {
    return struct {
        const Self = @This();

        //shared file descriptor
        fd: i32 = -1,
        c: xev.Completion = .{},

        //hashed path
        hash: u32,

        next: ?*Self = null,
        rb_node: tree.IntrusiveField(Self) = .{},
        completions: double.Intrusive(Completion) = .{},

    };
}

pub const Completion = struct {
    next: ?*Completion = null,
    prev: ?*Completion = null,

    userdata: ?*anyopaque = null,

    callback: Callback = NoopCallback,

    hash: u32 = 0,

    flags: packed struct {
        state: State = .dead,
    } = .{},

    const State = enum(u1) {
        dead = 0,

        active = 1,
    };

    pub fn state(self: Completion) CompletionState {
        return switch (self.flags.state) {
            .dead => .dead,
            .active => .active,
        };
    }

    pub fn invoke(self: *Completion, res: u32) CallbackAction {
        return self.callback(self.userdata, self, res);
    }
};

pub const Result = enum {};

pub fn FileSystemTest(comptime xev: type) type {
    return struct {
        const testing = std.testing;
        const FS = FileSystem(xev);

        test "test inotify file system watcher" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = try FS.init();
            defer fs.deinit();

            // Test Case 1: Watch a single path with multiple completions
            const path1 = "test_path_1";
            _ = try std.fs.cwd().createFile(path1, .{});
            defer std.fs.cwd().deleteFile(path1) catch {};
            var comp1_1: Completion = .{};
            var comp1_2: Completion = .{};
            var comp1_3: Completion = .{};

            try fs.watch(&loop, path1, &comp1_1);
            try fs.watch(&loop, path1, &comp1_2);
            try fs.watch(&loop, path1, &comp1_3);

            // // Test Case 2: Watch multiple distinct paths, each with one completion
            //
            const path2 = "test_path_2";
            const path3 = "test_path_3";
            var comp2_1: Completion = .{};
            var comp3_1: Completion = .{};

            _ = try std.fs.cwd().createFile(path2, .{});
            defer std.fs.cwd().deleteFile(path2) catch {};
            _ = try std.fs.cwd().createFile(path3, .{});
            defer std.fs.cwd().deleteFile(path3) catch {};

            try fs.watch(&loop, path2, &comp2_1);
            try fs.watch(&loop, path3, &comp3_1);

            // Test Case 3: Watch multiple distinct paths, each with multiple completions
            const path4 = "test_path_4";
            const path5 = "test_path_5";
            _ = try std.fs.cwd().createFile(path4, .{});
            defer std.fs.cwd().deleteFile(path4) catch {};
            _ = try std.fs.cwd().createFile(path5, .{});
            defer std.fs.cwd().deleteFile(path5) catch {};
            var comp4_1: Completion = .{};
            var comp4_2: Completion = .{};
            var comp5_1: Completion = .{};
            var comp5_2: Completion = .{};
            var comp5_3: Completion = .{};

            try fs.watch(&loop, path4, &comp4_1);
            try fs.watch(&loop, path4, &comp4_2);
            try fs.watch(&loop, path5, &comp5_1);
            try fs.watch(&loop, path5, &comp5_2);
            try fs.watch(&loop, path5, &comp5_3);

            try testing.expectEqual(fs.pool.countFree(), 95);

            fs.cancel(&comp4_1);
            fs.cancel(&comp4_2);
            fs.cancel(&comp5_1);
            fs.cancel(&comp5_2);
            fs.cancel(&comp5_3);

            try testing.expectEqual(fs.pool.countFree(), 97);
        }

        test "test inotify polling" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = try FS.init();
            defer fs.deinit();

            _ = try loop.run(.no_wait);

            const path1 = "test_path_1";
            const file = try std.fs.cwd().createFile(path1, .{});
            defer std.fs.cwd().deleteFile(path1) catch {};

            var counter: usize = 0;
            const custom_callback = struct {
                fn invoke(ud: ?*anyopaque, _: *Completion, _: u32) CallbackAction {
                    const cnt: *usize = @ptrCast(@alignCast(ud.?));
                    cnt.* += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: Completion = .{
                .userdata = &counter, // Pass the address of the counter
                .callback = custom_callback,
            };

            try fs.watch(&loop, path1, &comp);

            _ = try loop.run(.no_wait);

            _ = try file.write("hello");
            try file.sync();

            _ = try loop.run(.once);

            // Assert that the callback was invoked
            try testing.expectEqual(counter, 1);

            var counter2: usize = 0;

            var comp2: Completion = .{
                .userdata = &counter2, // Pass the address of the counter
                .callback = custom_callback,
            };

            try fs.watch(&loop, path1, &comp2);

            _ = try file.write("hello");
            try file.sync();

            // Run the event loop to process the inotify event
            _ = try loop.run(.no_wait);

            // Assert that the callback was invoked
            try testing.expectEqual(counter, 2);
            try testing.expectEqual(counter2, 1);
        }
    };
}
