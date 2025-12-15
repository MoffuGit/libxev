const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const double = @import("../../queue_double.zig");
const tree = @import("../../tree.zig");
const fspkg = @import("../fs.zig");
const common = @import("../common.zig");
const log = std.log.scoped(.fs);

pub fn FileSystem(comptime xev: type) type {
    return struct {
        const Self = @This();

        const Callback = fspkg.Callback(xev, @This());
        const NoopCallback = fspkg.NoopCallback(xev, @This());

        const State = enum(u1) {
            dead = 0,
            active = 1,
        };

        pub const Watcher = struct {
            rb_node: tree.IntrusiveField(Watcher) = .{},

            next: ?*Watcher = null,
            prev: ?*Watcher = null,

            userdata: ?*anyopaque = null,
            callback: Callback = NoopCallback,

            wd: i32 = 0,
            path: []const u8 = undefined,

            flags: packed struct {
                state: State = .dead,
            } = .{},

            watchers: double.Intrusive(Watcher) = .{},

            pub fn state(self: Watcher) State {
                return switch (self.flags.state) {
                    .dead => .dead,
                    .active => .active,
                };
            }

            pub fn invoke(self: *Watcher, path: []const u8, res: u32) xev.CallbackAction {
                return self.callback(self.userdata, self, path, res);
            }

            pub fn compare(a: *Watcher, b: *Watcher) std.math.Order {
                if (a.wd > b.wd) return .gt;
                if (a.wd < b.wd) return .lt;
                return .eq;
            }
        };

        fd: posix.fd_t = -1,
        c: xev.Completion = .{},
        active: usize = 0,

        tree: tree.Intrusive(Watcher, Watcher.compare) = .{},

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            //WARN:
            //i need to cancel the poll completion
            // self.loop.cancel(self.c);
            // posix.close(self.fd);
        }

        pub fn start(self: *Self, loop: *xev.Loop) !void {
            if (self.fd != -1) {
                return;
            }

            const fd = try posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);

            self.fd = fd;

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

        pub fn watch(self: *Self, path: []const u8, watcher: *Watcher, comptime Userdata: type, userdata: ?*Userdata, comptime cb: *const fn (
            ud: ?*Userdata,
            watcher: *Watcher,
            path: []const u8,
            result: u32,
        ) xev.CallbackAction) !void {
            if (watcher.state() != .dead) {
                return;
            }

            const wd = try posix.inotify_add_watch(self.fd, path, linux.IN.ATTRIB |
                linux.IN.CREATE |
                linux.IN.MODIFY |
                linux.IN.DELETE |
                linux.IN.DELETE_SELF |
                linux.IN.MOVE_SELF |
                linux.IN.MOVED_FROM |
                linux.IN.MOVED_TO);

            watcher.* = .{ .userdata = userdata, .callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    _watcher: *Watcher,
                    _path: []const u8,
                    result: u32,
                ) xev.CallbackAction {
                    return @call(.always_inline, cb, .{ common.userdataValue(Userdata, ud), _watcher, _path, result });
                }
            }).callback, .wd = wd };

            if (self.tree.find(watcher)) |w| {
                w.watchers.push(watcher);
            } else {
                self.tree.insert(watcher);
            }

            watcher.flags.state = .active;
            self.active += 1;
        }

        pub fn cancel(self: *Self, w: *Watcher) void {
            if (self.tree.find(w)) |watcher| {
                self.active -= 1;
                watcher.flags.state = .dead;

                if (watcher != w) {
                    watcher.watchers.remove(w);

                    return;
                }

                if (watcher.watchers.pop()) |replace| {
                    self.tree.replace(watcher, replace) catch {};
                } else {
                    _ = self.tree.remove(w);
                    posix.inotify_rm_watch(self.fd, w.wd);
                }
            }
        }

        pub fn cancelWithCallback(self: *Self, w: *Watcher, comptime Userdata: type, userdata: ?*Userdata, comptime cb: *const fn (ud: ?*Userdata, w: *Watcher) void) void {
            if (self.tree.find(w)) |watcher| {
                self.active -= 1;
                w.flags.state = .dead;

                if (watcher != w) {
                    watcher.watchers.remove(w);
                    @call(.always_inline, cb, .{ userdata, w });
                    return;
                }

                if (watcher.watchers.pop()) |replace| {
                    self.tree.replace(watcher, replace) catch {};
                } else {
                    _ = self.tree.remove(w);
                    posix.inotify_rm_watch(self.fd, w.wd);
                }

                @call(.always_inline, cb, .{ userdata, watcher });
            }
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
                        const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));

                        var temp = Watcher{ .wd = event.wd };
                        if (self.tree.find(&temp)) |watcher| {
                            var path: []const u8 = undefined;

                            if (event.getName()) |p| {
                                const w_path_len = watcher.path.len;
                                const p_len = p.len;
                                var _buffer: [std.fs.max_path_bytes]u8 = undefined;

                                if (w_path_len + 1 + p_len > std.fs.max_path_bytes) {
                                    @panic("Combined path exceeds maximum buffer length");
                                }

                                @memcpy(_buffer[0..w_path_len], watcher.path);
                                var current_idx: usize = w_path_len;

                                _buffer[current_idx] = '/';
                                current_idx += 1;

                                @memcpy(_buffer[current_idx .. current_idx + p_len], p);
                                current_idx += p_len;

                                path = _buffer[0..current_idx];
                            } else {
                                path = watcher.path;
                            }

                            const action = watcher.invoke(path, event.mask);

                            var current = watcher.watchers;
                            watcher.watchers = .{};

                            while (current.pop()) |c| {
                                if (c.invoke(path, event.mask) == .rearm) {
                                    watcher.watchers.push(c);
                                } else {
                                    c.flags.state = .dead;
                                    self.active -= 1;
                                }
                            }

                            if (action == .disarm) {
                                watcher.flags.state = .dead;
                                self.active -= 1;
                                if (watcher.watchers.pop()) |replace| {
                                    self.tree.replace(watcher, replace) catch {};
                                } else {
                                    _ = self.tree.remove(watcher);
                                    posix.inotify_rm_watch(self.fd, watcher.wd);
                                }
                            }
                        }

                        offset += @sizeOf(linux.inotify_event) + event.len;
                    }
                }
                return .rearm;
            } else |err| {
                log.debug("error poll {}", .{err});
                return .disarm;
            }
        }

        test {
            _ = FileSystemTest(xev);
        }
    };
}

pub const Result = enum {};

pub fn FileSystemTest(comptime xev: type) type {
    return struct {
        const testing = std.testing;
        const FS = FileSystem(xev);

        test "test inotify file watcher" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            _ = try loop.run(.no_wait);

            const path1 = "test_path_1";
            const file = try std.fs.cwd().createFile(path1, .{});
            defer std.fs.cwd().deleteFile(path1) catch {};

            var counter: usize = 0;

            const custom_callback = struct {
                fn invoke(ud: ?*usize, _: *FS.Watcher, _: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Watcher = .{};

            try fs.watch(path1, &comp, usize, &counter, custom_callback);

            _ = try file.write("hello");
            try file.sync();

            // Run the event loop to process the inotify event
            _ = try loop.run(.no_wait);

            // Assert that the callback was invoked
            try testing.expectEqual(counter, 1);

            var counter2: usize = 0;

            var comp2: FS.Watcher = .{};

            try fs.watch(path1, &comp2, usize, &counter2, custom_callback);

            _ = try file.write("hello");
            try file.sync();

            // Run the event loop to process the inotify event
            _ = try loop.run(.no_wait);

            // Assert that the callback was invoked
            try testing.expectEqual(counter, 2);
            try testing.expectEqual(counter2, 1);
        }

        test "test inotify directory watcher" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const dir_path = "test_directory_inotify";
            try std.fs.cwd().makeDir(dir_path);
            defer std.fs.cwd().deleteDir(dir_path) catch {};

            const Event = struct { count: usize, flags: u32 };

            var event = Event{ .count = 0, .flags = 0 };
            const dir_callback_fn = struct {
                fn invoke(evt: ?*Event, _: *FS.Watcher, _: []const u8, flags: u32) xev.CallbackAction {
                    evt.?.flags = flags;
                    evt.?.count += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Watcher = .{};

            try fs.watch(dir_path, &comp, Event, &event, dir_callback_fn);
            _ = try loop.run(.no_wait);

            try testing.expectEqual(event.count, 0);

            const file1_path = dir_path ++ "/file1.txt";
            _ = try std.fs.cwd().createFile(file1_path, .{});

            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 1);
            try testing.expectEqual(linux.IN.CREATE, event.flags);

            std.fs.cwd().deleteFile(file1_path) catch {};

            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 2);
            try testing.expectEqual(linux.IN.DELETE, event.flags);

            _ = try std.fs.cwd().createFile(file1_path, .{});
            defer std.fs.cwd().deleteFile(file1_path) catch {};

            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 3);
            try testing.expectEqual(linux.IN.CREATE, event.flags);

            var file_handle = try std.fs.cwd().openFile(file1_path, .{ .mode = .read_write });
            defer file_handle.close();
            _ = try file_handle.write("some content");
            try file_handle.sync();

            _ = try loop.run(.no_wait);
            try testing.expectEqual(event.count, 4);
            try testing.expectEqual(linux.IN.MODIFY, event.flags);
        }
        test "test inotify directory watcher for subdirectory events" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const parent_dir_path = "test_parent_dir_inotify_subdir";
            const sub_dir_path = parent_dir_path ++ "/test_subdir";
            const file_in_subdir_path = sub_dir_path ++ "/file_in_subdir.txt";

            try std.fs.cwd().makeDir(parent_dir_path);
            defer std.fs.cwd().deleteTree(parent_dir_path) catch {};

            const Event = struct { count: usize, flags: u32 };
            var event = Event{ .count = 0, .flags = 0 };

            const dir_callback_fn = struct {
                fn invoke(evt: ?*Event, _: *FS.Watcher, _: []const u8, flags: u32) xev.CallbackAction {
                    evt.?.flags = flags;
                    evt.?.count += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Watcher = .{};

            try fs.watch(parent_dir_path, &comp, Event, &event, dir_callback_fn);
            _ = try loop.run(.no_wait);

            try testing.expectEqual(event.count, 0);

            try std.fs.cwd().makeDir(sub_dir_path);
            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 1);
            try testing.expectEqual(event.flags, linux.IN.CREATE | linux.IN.ISDIR);

            event.flags = 0;

            _ = try std.fs.cwd().createFile(file_in_subdir_path, .{});
            _ = try loop.run(.no_wait);

            try testing.expectEqual(event.count, 1);
            try testing.expectEqual(event.flags, 0);
        }

        test "test cancelling a primary watcher without replacement" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const path = "test_path_cancel_no_replacement";
            _ = try std.fs.cwd().createFile(path, .{});
            defer std.fs.cwd().deleteFile(path) catch {};

            var counter: usize = 0;
            const callback_rearm = struct {
                fn invoke(ud: ?*usize, _: *FS.Watcher, _: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .rearm;
                }
            }.invoke;

            var watcher: FS.Watcher = .{};
            try fs.watch(path, &watcher, usize, &counter, callback_rearm);
            try testing.expectEqual(fs.active, 1);

            _ = try loop.run(.no_wait);

            const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
            defer file.close();
            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);
            try testing.expectEqual(watcher.flags.state, .active);

            fs.cancel(&watcher);
            _ = try loop.run(.no_wait);
            try testing.expectEqual(fs.active, 0);

            try testing.expectEqual(watcher.flags.state, .dead);

            _ = try file.write("event 2");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);

            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);
            try testing.expectEqual(watcher.flags.state, .dead);

            try testing.expectEqual(watcher.flags.state, .dead);
            try testing.expectEqual(fs.active, 0);
        }

        test "test disarm a primary watcher without replacement" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const path = "test_path_cancel_no_replacement";
            _ = try std.fs.cwd().createFile(path, .{});
            defer std.fs.cwd().deleteFile(path) catch {};

            var counter: usize = 0;
            const callback_rearm = struct {
                fn invoke(ud: ?*usize, _: *FS.Watcher, _: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .disarm;
                }
            }.invoke;

            var watcher: FS.Watcher = .{};
            try fs.watch(path, &watcher, usize, &counter, callback_rearm);

            _ = try loop.run(.no_wait);

            const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
            defer file.close();
            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);
            try testing.expectEqual(watcher.flags.state, .dead);

            try testing.expectEqual(watcher.flags.state, .dead);
            try testing.expectEqual(fs.active, 0);

            _ = try file.write("event 2");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);

            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);
            try testing.expectEqual(watcher.flags.state, .dead);

            try testing.expectEqual(watcher.flags.state, .dead);
            try testing.expectEqual(fs.active, 0);
        }

        test "test cancelling a primary watcher with a custom callback" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const path = "test_path_cancel_with_callback";
            _ = try std.fs.cwd().createFile(path, .{});
            defer std.fs.cwd().deleteFile(path) catch {};

            var watch_counter: usize = 0;
            const watch_callback_rearm = struct {
                fn invoke(ud: ?*usize, _: *FS.Watcher, _: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .rearm;
                }
            }.invoke;

            var cancel: bool = false;

            const cancel_callback = struct {
                fn invoke(ud: ?*bool, w: *FS.Watcher) void {
                    _ = w;
                    ud.?.* = true;
                }
            }.invoke;

            var watcher: FS.Watcher = .{};
            try fs.watch(path, &watcher, usize, &watch_counter, watch_callback_rearm);
            try testing.expectEqual(fs.active, 1);
            try testing.expectEqual(watcher.flags.state, .active);

            _ = try loop.run(.no_wait);

            // Trigger an event to ensure the watcher is active and registered
            const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
            defer file.close();
            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.once);
            try testing.expectEqual(watch_counter, 1);
            try testing.expectEqual(watcher.flags.state, .active);

            fs.cancelWithCallback(&watcher, bool, &cancel, cancel_callback);
            _ = try loop.run(.no_wait);

            try testing.expectEqual(cancel, true);
            try testing.expectEqual(fs.active, 0);
            try testing.expectEqual(watcher.flags.state, .dead);

            // Verify no further watch events occur after cancellation
            _ = try file.write("event 2 after cancel");
            try file.sync();
            _ = try loop.run(.no_wait);
            try testing.expectEqual(watch_counter, 1); // Should not increment further
        }

        test "test multiple watchers cancelation" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const path = "test_multiple_watchers_path";
            const file = try std.fs.cwd().createFile(path, .{});
            defer std.fs.cwd().deleteFile(path) catch {};

            var event_counter_1: usize = 0;
            var event_counter_2: usize = 0;
            var event_counter_3: usize = 0;

            const watch_callback_rearm = struct {
                fn invoke(ud: ?*usize, _: *FS.Watcher, _: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .rearm;
                }
            }.invoke;

            var cancel_flag_1: bool = false;
            var cancel_flag_3: bool = false;

            const simple_cancel_callback = struct {
                fn invoke(ud: ?*bool, w: *FS.Watcher) void {
                    _ = w;
                    ud.?.* = true;
                }
            }.invoke;

            var watcher_1: FS.Watcher = .{};
            try fs.watch(path, &watcher_1, usize, &event_counter_1, watch_callback_rearm);
            try testing.expectEqual(fs.active, 1);
            try testing.expectEqual(watcher_1.flags.state, .active);

            _ = try loop.run(.no_wait);

            _ = try file.write("event 1a");
            try file.sync();

            _ = try loop.run(.once);

            try testing.expectEqual(event_counter_1, 1);
            try testing.expectEqual(event_counter_2, 0);
            try testing.expectEqual(event_counter_3, 0);
            try testing.expectEqual(watcher_1.flags.state, .active);

            var watcher_2: FS.Watcher = .{};
            try fs.watch(path, &watcher_2, usize, &event_counter_2, watch_callback_rearm);
            try testing.expectEqual(fs.active, 2);
            try testing.expectEqual(watcher_2.flags.state, .active);
            try testing.expectEqual(event_counter_2, 0);

            var watcher_3: FS.Watcher = .{};
            try fs.watch(path, &watcher_3, usize, &event_counter_3, watch_callback_rearm);

            try testing.expectEqual(fs.active, 3);
            try testing.expectEqual(watcher_3.flags.state, .active);
            try testing.expectEqual(event_counter_3, 0);

            _ = try file.write("event after all added");
            try file.sync();
            _ = try loop.run(.once);

            try testing.expectEqual(event_counter_1, 2);
            try testing.expectEqual(event_counter_2, 1);
            try testing.expectEqual(event_counter_3, 1);

            fs.cancelWithCallback(&watcher_3, bool, &cancel_flag_3, simple_cancel_callback);

            try testing.expectEqual(cancel_flag_3, true);
            try testing.expectEqual(fs.active, 2);
            try testing.expectEqual(watcher_3.flags.state, .dead);

            _ = try file.write("event after cancel 3");
            try file.sync();

            _ = try loop.run(.once);

            try testing.expectEqual(event_counter_1, 3);
            try testing.expectEqual(event_counter_2, 2);
            try testing.expectEqual(event_counter_3, 1);

            fs.cancelWithCallback(&watcher_1, bool, &cancel_flag_1, simple_cancel_callback);

            _ = try loop.run(.no_wait);

            try testing.expectEqual(event_counter_1, 3);
            try testing.expectEqual(cancel_flag_1, true);
            try testing.expectEqual(fs.active, 1);
            try testing.expectEqual(watcher_1.flags.state, .dead);

            _ = try file.write("event after cancel 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(event_counter_1, 3);
            try testing.expectEqual(event_counter_2, 3);
            try testing.expectEqual(event_counter_3, 1);
            try testing.expectEqual(watcher_2.flags.state, .active);

            fs.cancel(&watcher_2);
            _ = try loop.run(.no_wait);

            try testing.expectEqual(fs.active, 0);
            try testing.expectEqual(watcher_2.flags.state, .dead);

            _ = try file.write("event after cancel 2");
            try file.sync();

            _ = try loop.run(.no_wait);
            try testing.expectEqual(event_counter_1, 3);
            try testing.expectEqual(event_counter_2, 3);
            try testing.expectEqual(event_counter_3, 1);
        }
    };
}
