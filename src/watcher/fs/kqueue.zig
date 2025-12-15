const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const double = @import("../../queue_double.zig");
const tree = @import("../../tree.zig");
const fspkg = @import("../fs.zig");
const common = @import("../common.zig");
const log = std.log.scoped(.fs);
const Fnv1a_32 = std.hash.Fnv1a_32;

pub fn FileSystem(comptime xev: type) type {
    return struct {
        const Self = @This();

        const Callback = fspkg.Callback(xev, @This());
        const NoopCallback = fspkg.NoopCallback(xev, @This());

        const CancelationCallback = fspkg.CancelationCallback(@This());
        const NoopCancelation = fspkg.NoopCancelation(@This());

        const State = enum(u1) {
            dead = 0,
            active = 1,
        };

        const Cancelation = struct {
            c: xev.Completion = .{},
            userdata: ?*anyopaque = null,
            callback: CancelationCallback = NoopCancelation,

            pub fn invoke(self: *Cancelation, w: *Watcher) void {
                self.callback(self.userdata, w);
            }
        };

        pub const Monitor = struct {
            const FLAGS = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.ATTRIB | std.c.NOTE.EXTEND | std.c.NOTE.LINK | std.c.NOTE.RENAME;
            fd: i32 = -1,

            c: xev.Completion = .{},

            watchers: double.Intrusive(Watcher) = .{},
            cancelation: Cancelation = .{},

            pub fn state(self: Monitor) State {
                return if (self.fd == 1) .dead else .active;
            }

            pub fn init(path: []const u8) !Monitor {
                const fd = try posix.open(path, .{}, 0);

                return .{ .fd = fd };
            }

            pub fn start(self: *Monitor, loop: *xev.Loop, w: *Watcher) void {
                self.c = .{
                    .op = .{
                        .vnode = .{
                            .fd = self.fd,
                            .flags = FLAGS,
                        },
                    },
                    .userdata = w,
                    .callback = vnode_callback,
                };
                loop.add(&self.c);
            }

            pub fn cancel(self: *Monitor, loop: *xev.Loop, w: *Watcher) void {
                self.cancelation.c =
                    .{ .op = .{ .cancel = .{ .c = &self.c } }, .userdata = w, .callback = cancel_callback };
                loop.add(&self.cancelation.c);
            }

            pub fn deinit(self: *Monitor) void {
                _ = self;
            }
        };

        pub const Watcher = struct {
            fs: ?*Self = null,

            rb_node: tree.IntrusiveField(Watcher) = .{},

            next: ?*Watcher = null,
            prev: ?*Watcher = null,

            userdata: ?*anyopaque = null,
            callback: Callback = NoopCallback,

            wd: u32 = 0,
            path: []const u8 = undefined,

            monitor: Monitor = .{},

            flags: packed struct {
                state: State = .dead,
            } = .{},

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

        tree: tree.Intrusive(Watcher, Watcher.compare) = .{},
        loop: *xev.Loop = undefined,
        active: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            //NOTE:
            //assume that the loop is stoped or already removed from memory
            //you need to close every fd, for that you need to iter over the tree
        }

        pub fn start(self: *Self, loop: *xev.Loop) !void {
            self.loop = loop;
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

            const wd = Fnv1a_32.hash(path);

            watcher.* = .{ .callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    _watcher: *Watcher,
                    _path: []const u8,
                    result: u32,
                ) xev.CallbackAction {
                    return @call(.always_inline, cb, .{ common.userdataValue(Userdata, ud), _watcher, _path, result });
                }
            }).callback, .userdata = userdata, .wd = wd, .path = path, .fs = self };

            if (self.tree.find(watcher)) |w| {
                w.monitor.watchers.push(watcher);
            } else {
                watcher.monitor = try Monitor.init(path);

                watcher.monitor.start(self.loop, watcher);

                self.tree.insert(watcher);
            }

            watcher.flags.state = .active;
            self.active += 1;
        }

        pub fn cancel(self: *Self, watcher: *Watcher) void {
            if (self.tree.find(watcher)) |w| {
                const m = &w.monitor;

                if (watcher != w) {
                    watcher.*.flags.state = .dead;
                    self.active -= 1;
                    m.watchers.remove(watcher);
                    return;
                }

                if (m.watchers.pop()) |replace| {
                    replace.monitor = Monitor.init(replace.path) catch {
                        return;
                    };

                    replace.monitor.start(self.loop, replace);

                    self.tree.replace(w, replace) catch {};
                } else {
                    _ = self.tree.remove(w);
                }

                m.cancel(self.loop, w);
            }
        }

        pub fn cancelWithCallback(self: *Self, watcher: *Watcher, comptime Userdata: type, userdata: ?*Userdata, comptime cb: *const fn (ud: ?*Userdata, w: *Watcher) void) void {
            if (self.tree.find(watcher)) |w| {
                const m = &w.monitor;

                m.cancelation = .{ .userdata = userdata, .callback = (struct {
                    pub fn callback(ud: ?*anyopaque, inner_w: *Watcher) void {
                        @call(.always_inline, cb, .{ common.userdataValue(Userdata, ud), inner_w });
                    }
                }.callback) };

                if (watcher != w) {
                    watcher.flags.state = .dead;
                    self.active -= 1;
                    m.watchers.remove(watcher);
                    m.cancelation.invoke(w);
                    return;
                }

                m.cancel(self.loop, w);

                if (m.watchers.pop()) |replace| {
                    replace.monitor = Monitor.init(replace.path) catch {
                        return;
                    };

                    replace.monitor.start(self.loop, replace);

                    self.tree.replace(w, replace) catch {};
                } else {
                    _ = self.tree.remove(w);
                }
            }
        }

        fn cancel_callback(ud: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, _: xev.Result) xev.CallbackAction {
            const watcher: *Watcher = @ptrCast(@alignCast(ud.?));

            watcher.*.flags.state = .dead;
            watcher.fs.?.active -= 1;
            posix.close(watcher.monitor.fd);
            watcher.monitor.fd = -1;

            watcher.monitor.cancelation.invoke(watcher);

            return .disarm;
        }

        fn vnode_callback(
            ud: ?*anyopaque,
            loop: *xev.Loop,
            _: *xev.Completion,
            result: xev.Result,
        ) xev.CallbackAction {
            const watcher: *Watcher = @ptrCast(@alignCast(ud.?));

            const vnode_flags = result.vnode catch {
                return .disarm;
            };

            var watchers = watcher.monitor.watchers;
            watcher.monitor.watchers = .{};

            const action = watcher.invoke(watcher.path, vnode_flags);

            var curr = watchers.pop();
            while (curr) |w| {
                switch (w.invoke(watcher.path, vnode_flags)) {
                    .disarm => {
                        w.flags.state = .dead;
                        w.fs.?.active -= 1;
                    },
                    .rearm => {
                        watcher.monitor.watchers.push(w);
                    },
                }
                curr = watchers.pop();
            }

            if (action == .disarm) {
                if (watcher.monitor.watchers.pop()) |replace| {
                    replace.monitor = Monitor.init(replace.path) catch {
                        return action;
                    };

                    replace.monitor.start(loop, replace);

                    watcher.fs.?.tree.replace(watcher, replace) catch {};
                } else {
                    _ = watcher.fs.?.tree.remove(watcher);
                }

                watcher.monitor.cancel(loop, watcher);
            }

            return action;
        }
        test {
            _ = FileSystemTest(xev);
        }
    };
}

pub fn FileSystemTest(comptime xev: type) type {
    return struct {
        const testing = std.testing;
        const assert = std.debug.assert;
        const FS = FileSystem(xev);

        test "test kqueue vnode" {
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
                fn invoke(ud: ?*usize, _: *FS.Watcher, path: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    assert(std.mem.eql(u8, path1, path));
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Watcher = .{};

            try fs.watch(path1, &comp, usize, &counter, custom_callback);
            try testing.expectEqual(fs.active, 1);

            _ = try loop.run(.no_wait);

            _ = try file.write("hello");
            try file.sync();

            _ = try loop.run(.once);

            try testing.expectEqual(counter, 1);

            var counter2: usize = 0;

            var comp2: FS.Watcher = .{};

            try fs.watch(path1, &comp2, usize, &counter2, custom_callback);
            try testing.expectEqual(fs.active, 2);

            _ = try file.write("hello");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 2);
            try testing.expectEqual(counter2, 1);
        }

        test "test kqueue directory watcher" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const dir_path = "test_directory_kqueue";
            try std.fs.cwd().makeDir(dir_path);
            defer std.fs.cwd().deleteDir(dir_path) catch {};

            const Event = struct { count: usize, flags: u32 };

            var event = Event{ .count = 0, .flags = 0 };
            const dir_callback_fn = struct {
                fn invoke(evt: ?*Event, _: *FS.Watcher, path: []const u8, flags: u32) xev.CallbackAction {
                    evt.?.flags = flags;
                    evt.?.count += 1;
                    assert(std.mem.eql(u8, dir_path, path));
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Watcher = .{};

            try fs.watch(dir_path, &comp, Event, &event, dir_callback_fn);
            try testing.expectEqual(fs.active, 1);
            _ = try loop.run(.no_wait);

            try testing.expectEqual(event.count, 0);

            const file1_path = dir_path ++ "/file1.txt";
            _ = try std.fs.cwd().createFile(file1_path, .{});

            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 1);
            try testing.expectEqual(std.c.NOTE.WRITE, event.flags);

            std.fs.cwd().deleteFile(file1_path) catch {};

            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 2);
            try testing.expectEqual(std.c.NOTE.WRITE, event.flags);

            _ = try std.fs.cwd().createFile(file1_path, .{});
            defer std.fs.cwd().deleteFile(file1_path) catch {};

            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 3);
            try testing.expectEqual(std.c.NOTE.WRITE, event.flags);

            var file_handle = try std.fs.cwd().openFile(file1_path, .{ .mode = .read_write });
            defer file_handle.close();
            _ = try file_handle.write("some content");
            try file_handle.sync();

            _ = try loop.run(.no_wait);
            try testing.expectEqual(event.count, 3);
        }

        test "test kqueue directory watcher for subdirectory events" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const parent_dir_path = "test_parent_dir_kqueue_subdir";
            const sub_dir_path = parent_dir_path ++ "/test_subdir";

            try std.fs.cwd().makeDir(parent_dir_path);
            defer std.fs.cwd().deleteTree(parent_dir_path) catch {};

            const Event = struct { count: usize, flags: u32 };
            var event = Event{ .count = 0, .flags = 0 };

            const dir_callback_fn = struct {
                fn invoke(evt: ?*Event, _: *FS.Watcher, path: []const u8, flags: u32) xev.CallbackAction {
                    evt.?.flags = flags;
                    assert(std.mem.eql(u8, parent_dir_path, path));
                    evt.?.count += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Watcher = .{};

            try fs.watch(parent_dir_path, &comp, Event, &event, dir_callback_fn);
            try testing.expectEqual(fs.active, 1);
            _ = try loop.run(.no_wait);

            try testing.expectEqual(event.count, 0);

            try std.fs.cwd().makeDir(sub_dir_path);
            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 1);
            try testing.expectEqual(event.flags, std.c.NOTE.WRITE | std.c.NOTE.LINK);

            const renamed_sub_dir_path = parent_dir_path ++ "/renamed_sub_dir_path";

            try std.fs.cwd().rename(sub_dir_path, renamed_sub_dir_path);

            _ = try loop.run(.no_wait);
            try testing.expectEqual(event.count, 2);
            try testing.expectEqual(event.flags, std.c.NOTE.WRITE);

            event.flags = 0;

            const file_in_subdir_path = renamed_sub_dir_path ++ "/file_in_subdir.txt";

            _ = try std.fs.cwd().createFile(file_in_subdir_path, .{});
            _ = try loop.run(.no_wait);

            try testing.expectEqual(event.count, 2);
            try testing.expectEqual(event.flags, 0);
        }
        test "test vnode_callback with disarming watchers and primary replacement" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();
            try fs.start(&loop);

            const path = "test_path_disarm_replacement";
            _ = try std.fs.cwd().createFile(path, .{});
            defer std.fs.cwd().deleteFile(path) catch {};

            var counter_A: usize = 0;
            const callback_A_disarm = struct {
                fn invoke(ud: ?*usize, _: *FS.Watcher, _: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .disarm;
                }
            }.invoke;

            var watcher_A: FS.Watcher = .{};
            try fs.watch(path, &watcher_A, usize, &counter_A, callback_A_disarm);
            try testing.expectEqual(fs.active, 1);

            var counter_B: usize = 0;
            const callback_B_rearm = struct {
                fn invoke(ud: ?*usize, _: *FS.Watcher, _: []const u8, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .rearm;
                }
            }.invoke;

            var watcher_B: FS.Watcher = .{};
            try fs.watch(path, &watcher_B, usize, &counter_B, callback_B_rearm);
            try testing.expectEqual(fs.active, 2);

            _ = try loop.run(.no_wait);

            try testing.expectEqual(watcher_A.flags.state, .active);

            const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
            defer file.close();
            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.once);
            _ = try loop.run(.once);

            try testing.expectEqual(counter_A, 1);
            try testing.expectEqual(counter_B, 1);
            try testing.expectEqual(watcher_A.flags.state, .dead);
            try testing.expectEqual(watcher_B.flags.state, .active);

            _ = try loop.run(.no_wait);

            _ = try file.write("event 2");
            try file.sync();

            _ = try loop.run(.once);

            try testing.expectEqual(counter_A, 1);
            try testing.expectEqual(counter_B, 2);
            try testing.expectEqual(watcher_A.flags.state, .dead);
            try testing.expectEqual(watcher_B.flags.state, .active);
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

            _ = try loop.run(.once);

            try testing.expectEqual(counter, 1);
            try testing.expectEqual(watcher.flags.state, .active);

            fs.cancel(&watcher);
            _ = try loop.run(.no_wait);
            try testing.expectEqual(fs.active, 0);

            try testing.expectEqual(watcher.flags.state, .dead);

            _ = try file.write("event 2");
            try file.sync();

            _ = try loop.run(.until_done);

            try testing.expectEqual(counter, 1);
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

            _ = try loop.run(.once);
            _ = try loop.run(.once);

            try testing.expectEqual(counter, 1);
            try testing.expectEqual(watcher.flags.state, .dead);

            fs.cancel(&watcher);
            _ = try loop.run(.no_wait);

            try testing.expectEqual(watcher.flags.state, .dead);
            try testing.expectEqual(fs.active, 0);

            _ = try file.write("event 2");
            try file.sync();

            _ = try loop.run(.until_done);

            try testing.expectEqual(counter, 1);
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

            _ = try loop.run(.once);

            try testing.expectEqual(cancel, true);
            try testing.expectEqual(fs.active, 0);
            try testing.expectEqual(watcher.flags.state, .dead);
            try testing.expectEqual(watcher.monitor.fd, -1); // Monitor's FD should be closed

            // Verify no further watch events occur after cancellation
            _ = try file.write("event 2 after cancel");
            try file.sync();
            _ = try loop.run(.once);
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

            _ = try loop.run(.once);

            try testing.expectEqual(event_counter_1, 3);
            try testing.expectEqual(cancel_flag_1, true);
            try testing.expectEqual(fs.active, 1);
            try testing.expectEqual(watcher_1.flags.state, .dead);
            try testing.expectEqual(watcher_1.monitor.fd, -1);

            const watcher_2_monitor = watcher_2.monitor;
            try testing.expect(watcher_2_monitor.fd > -1);
            try testing.expect(watcher_2.state() == .active);
            try testing.expectEqual(watcher_2_monitor.c.state(), .active);

            _ = try file.write("event after cancel 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(event_counter_1, 3);
            try testing.expectEqual(event_counter_2, 3);
            try testing.expectEqual(event_counter_3, 1);
            try testing.expectEqual(watcher_2.flags.state, .active);

            fs.cancel(&watcher_2);
            _ = try loop.run(.once);

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
