const inotify = @import("fs/inotify.zig");
const kqueue = @import("fs/kqueue.zig");
const std = @import("std");
const tree = @import("../tree.zig");
const double = @import("../queue_double.zig");

pub fn FileSystem(comptime xev: type) type {
    if (xev.dynamic) return FileSystemDynamic(xev);
    return switch (xev.backend) {
        .io_uring,
        .epoll,
        => inotify.FileSystem(xev),
        .kqueue => kqueue.FileSystem(xev),
        else => struct {},
    };
}

fn WatcherDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        pub const Union = xev.TaggedUnion(&.{"Watcher"});

        value: Self.Union = @unionInit(
            Self.Union,
            @tagName(xev.candidates[xev.candidates.len - 1]),
            .{},
        ),

        pub fn ensureTag(self: *Self, comptime tag: xev.Backend) void {
            if (self.value == tag) return;
            self.value = @unionInit(
                Self.Union,
                @tagName(tag),
                .{},
            );
        }
    };
}

fn FileSystemDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        pub const Union = xev.Union(&.{"FileSystem"});
        pub const Watcher = WatcherDynamic(xev);

        backend: Union,

        pub fn init() Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        api.FileSystem.init(),
                    );
                },
            } };
        }

        pub fn deinit(self: *Self) void {
            switch (xev.backend) {
                inline else => |tag| @field(
                    self.backend,
                    @tagName(tag),
                ).deinit(),
            }
        }

        pub fn watch(self: *Self, loop: *xev.Loop, path: []const u8, watcher: *xev.Watcher, comptime Userdata: type, userdata: ?*Userdata, comptime cb: *const fn (
            ud: ?*Userdata,
            watcher: *xev.Watcher,
            path: []const u8,
            result: u32,
        ) xev.CallbackAction) !void {
            switch (xev.backend) {
                inline else => |tag| {
                    watcher.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud: ?*Userdata,
                            w: *api.Watcher,
                            p: []const u8,
                            result: u32,
                        ) xev.CallbackAction {
                            return cb(
                                ud,
                                @fieldParentPtr(
                                    "value",
                                    @as(
                                        *xev.Watcher.Union,
                                        @fieldParentPtr(@tagName(tag), w),
                                    ),
                                ),
                                p,
                                result,
                            );
                        }
                    }.callback);
                    try @field(
                        self.backend,
                        @tagName(tag),
                    ).watch(&@field(loop.backend, @tagName(tag)), path, &@field(watcher.value, @tagName(tag)), Userdata, userdata, api_cb);
                },
            }
        }

        pub fn cancel(self: *Self, watcher: *xev.Watcher) void {
            switch (xev.backend) {
                inline else => |tag| {
                    watcher.ensureTag(tag);

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).cancel(&@field(watcher.value, @tagName(tag)));
                },
            }
        }

        test {
            _ = FileSystemTest(xev);
        }
    };
}

pub fn Callback(comptime xev: type, comptime T: type) type {
    return *const fn (
        userdata: ?*anyopaque,
        watcher: *T.Watcher,
        path: []const u8,
        result: u32,
    ) xev.CallbackAction;
}

pub fn NoopCallback(comptime xev: type, comptime T: type) Callback(xev, T) {
    return (struct {
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *T.Watcher,
            _: []const u8,
            _: u32,
        ) xev.CallbackAction {
            return .disarm;
        }
    }).noopCallback;
}

pub fn CancelationCallback(comptime T: type) type {
    return *const fn (
        userdata: ?*anyopaque,
        watcher: *T.Watcher,
    ) void;
}

pub fn NoopCancelation(comptime T: type) CancelationCallback(T) {
    return (struct {
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *T.Watcher,
        ) void {}
    }).noopCallback;
}

pub fn FileSystemTest(comptime xev: type) type {
    return struct {
        const linux = std.os.linux;
        const testing = std.testing;
        const FS = FileSystem(xev);

        test "test dynamic file watcher" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();

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

            var watcher: FS.Watcher = .{};

            try fs.watch(&loop, path1, &watcher, usize, &counter, custom_callback);

            _ = try file.write("hello");
            try file.sync();

            // Run the event loop to process the inotify event
            _ = try loop.run(.no_wait);

            // Assert that the callback was invoked
            try testing.expectEqual(counter, 1);

            var counter2: usize = 0;

            var comp2: FS.Watcher = .{};

            try fs.watch(&loop, path1, &comp2, usize, &counter2, custom_callback);

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

            try fs.watch(&loop, dir_path, &comp, Event, &event, dir_callback_fn);
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

            try fs.watch(&loop, parent_dir_path, &comp, Event, &event, dir_callback_fn);
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
            try fs.watch(&loop, path, &watcher, usize, &counter, callback_rearm);

            _ = try loop.run(.no_wait);

            const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
            defer file.close();
            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);

            fs.cancel(&watcher);
            _ = try loop.run(.no_wait);

            _ = try file.write("event 2");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);

            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);
        }

        test "test disarm a primary watcher without replacement" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = FS.init();
            defer fs.deinit();

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
            try fs.watch(&loop, path, &watcher, usize, &counter, callback_rearm);

            _ = try loop.run(.no_wait);

            const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
            defer file.close();
            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);

            _ = try file.write("event 2");
            try file.sync();

            _ = try loop.run(.no_wait);

            try testing.expectEqual(counter, 1);

            _ = try file.write("event 1");
            try file.sync();

            _ = try loop.run(.no_wait);
        }
    };
}
