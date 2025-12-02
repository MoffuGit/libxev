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

const WatcherPool = pool.Intrusive(FileWatcher);

const CAPACITY = 100;

fn compare(a: *FileWatcher, b: *FileWatcher) std.math.Order {
    if (a.wd > b.wd) return .gt;
    if (a.wd < b.wd) return .lt;
    return .eq;
}

pub fn FileSystem(comptime xev: type) type {
    return struct {
        fd: posix.fd_t = -1,
        c: xev.Completion = .{},
        buffer: [CAPACITY]FileWatcher = undefined,

        pool: WatcherPool = undefined,
        tree: tree.Intrusive(FileWatcher, compare) = .{},

        const Self = @This();

        pub fn init() !Self {
            return .{};
        }

        pub fn start(self: *Self, loop: *xev.Loop) !void {
            if (self.fd != -1) {
                return;
            }

            const fd = try posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);

            self.fd = fd;

            self.pool = WatcherPool.init(&self.buffer);

            const events: u32 = comptime switch (xev.backend) {
                .io_uring => posix.POLL.IN,
                .epoll => linux.EPOLL.IN,
                else => unreachable,
            };

            self.c = .{ .op = .{ .poll = .{
                .fd = self.fd,
                .events = events,
            } }, .userdata = self, .callback = poll_callback };

            loop.add(&self.c);
        }

        pub fn deinit(self: *Self) void {
            // self.loop.cancel(self.c);
            posix.close(self.fd);
        }

        pub fn poll_callback(ud: ?*anyopaque, _: *xev.Loop, poll_c: *xev.Completion, res: xev.Result) xev.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            if (res.poll) |_| {
                var buffer: [4096]u8 = undefined;
                while (true) {
                    const bytes_read = posix.read(poll_c.op.poll.fd, &buffer) catch |err| {
                        if (err == error.WouldBlock or err == error.Intr) {
                            break;
                        }
                        log.err("inotify read error: {}", .{err});
                        break;
                    };

                    if (bytes_read == 0) {
                        break;
                    }

                    var offset: usize = 0;
                    while (offset < bytes_read) {
                        const event_ptr: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
                        const event = event_ptr.*;

                        var temp_wd = FileWatcher{ .wd = event.wd };
                        if (self.tree.find(&temp_wd)) |watcher| {
                            var current = watcher.completions;
                            watcher.completions = .{};

                            while (current.pop()) |c| {
                                if (c.invoke(event.mask) == .rearm) {
                                    watcher.completions.push(c);
                                } else {
                                    c.*.flags.state = .dead;
                                }
                            }
                        } else {
                            // Watcher not found. This can happen if a watch was removed but events were
                            // still pending in the kernel buffer, or due to race conditions.
                            log.warn("inotify event for unknown wd: {}", .{event.wd});
                        }

                        // Advance to the next event in the buffer.
                        // event.len is the size of the filename string that follows the struct.
                        offset += @sizeOf(linux.inotify_event) + event.len;
                    }
                }
                return .rearm;
            } else |err| {
                log.debug("error poll {}", .{err});
                return .disarm;
            }
        }

        pub fn watch(self: *Self, loop: *xev.Loop, path: []const u8, c: *Completion) !void {
            try self.start(loop);

            const wd = try posix.inotify_add_watch(self.fd, path, linux.IN.ATTRIB |
                linux.IN.CREATE |
                linux.IN.MODIFY |
                linux.IN.DELETE |
                linux.IN.DELETE_SELF |
                linux.IN.MOVE_SELF |
                linux.IN.MOVED_FROM |
                linux.IN.MOVED_TO);

            var temp_wd = FileWatcher{ .wd = wd };

            if (self.tree.find(&temp_wd)) |w| {
                w.completions.push(c);
            } else {
                const w = try self.pool.alloc();
                w.* = .{ .wd = wd };
                w.completions.push(c);
                self.tree.insert(w);
            }

            c.*.flags.state = .active;
            c.*.wd = wd;
        }

        pub fn cancel(self: *Self, c: *Completion) void {
            var temp_wd = FileWatcher{ .wd = c.wd };

            if (self.tree.find(&temp_wd)) |watcher| {
                watcher.completions.remove(c);

                c.*.flags.state = .dead;

                if (watcher.completions.empty()) {
                    _ = self.tree.remove(watcher);
                    self.pool.free(watcher);
                    posix.inotify_rm_watch(self.fd, c.wd);
                }
            }
        }

        test {
            _ = FileSystemTest(xev);
        }
    };
}

pub const FileWatcher = struct {
    const Self = @This();

    wd: i32,

    next: ?*Self = null,
    rb_node: tree.IntrusiveField(Self) = .{},
    completions: double.Intrusive(Completion) = .{},
};

pub const Completion = struct {
    next: ?*Completion = null,
    prev: ?*Completion = null,

    userdata: ?*anyopaque = null,

    callback: Callback = NoopCallback,

    wd: i32 = -1,

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

            _ = try file.write("hello");
            try file.sync();

            // Run the event loop to process the inotify event
            _ = try loop.run(.no_wait);

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
