const std = @import("std");
const posix = std.posix;
const common = @import("common.zig");

pub fn FsEvents(comptime xev: type) type {
    if (xev.dynamic) return FsEventsDynamic(xev);

    return switch (xev.backend) {
        .io_uring => InotifyFsEvents(xev),
        .kqueue => KqueueFsEvents(xev),
        else => struct {}
    };
}

//NOTE:
//probably every event should return the path to what the event corresponse
//why?, because it will make every thing easier for the user to now what file change and why
//this is more important on directory watchers

//WARN:
//this thing don't remove the callbacks from the IWatcher,
//that mean that every cb that gets added will never be removed
//and that means that every IWatcher will ever exist,
//that's like bad, but right now i don't even have where to test this thing :(
//i need to redo my vm but i don't want to :(
pub fn InotifyFsEvents(comptime xev: type) type {
    return struct {
        const FsEventError = enum {
            Unexpected
        };

        pub const FsEvent = struct {
          delete: bool = false,
          write: bool = false,
          extend: bool = false,
          attrib: bool = false,
          rename: bool = false,
          revoke: bool = false,
        };

        const Self = @This();

        path: [std.c.PATH_MAX]u8,
        len: usize,

        pub fn init(path: []const u8) !Self {
            var res = Self {
                .path = undefined,
                .len = path.len,
            };

            @memcpy(res.path[0..path.len], path);

            return res;
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: FsEventError!FsEvent
            ) xev.CallbackAction,
        ) !void {
            try loop.init_inotify();

            const wd = try loop.inotify_add_watch(self.path);

            const w = if (loop.get_inotify_watcher(wd)) |existing_watcher|
              existing_watcher
            else blk: {
              break :blk try loop.init_inotify_watcher(wd);
            };

            c.* = .{
                .op = .{ .inotify = {} },
                .userdata = common.userdataValue(Userdata, userdata),
                .callback = (struct {
                    fn callback(
                        ud_inner: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const result: FsEventError!FsEvent = blk: {
                            const mask_u32 = r.inotify_event catch |err| {
                                std.debug.print("inotify_event error: {any}\n", .{err});
                                break :blk FsEventError.Unexpected;
                            };

                            var events: FsEvent = .{};
                            // Map inotify masks to FsEvent fields
                            if (mask_u32 & posix.IN.ATTRIB != 0) events.attrib = true;
                            if (mask_u32 & posix.IN.CREATE != 0) events.write = true;
                            if (mask_u32 & posix.IN.MODIFY != 0) events.write = true;
                            if (mask_u32 & posix.IN.DELETE != 0) events.delete = true;
                            if (mask_u32 & posix.IN.DELETE_SELF != 0) events.delete = true;
                            if (mask_u32 & posix.IN.MOVE_SELF != 0) events.rename = true;
                            if (mask_u32 & posix.IN.MOVED_FROM != 0) events.rename = true;
                            if (mask_u32 & posix.IN.MOVED_TO != 0) events.rename = true;
                            // Other inotify flags can be added as needed

                            break :blk events;
                        };

                        return @call(.always_inline, cb, .{
                            @as(?Userdata, @ptrCast(@alignCast(ud_inner))),
                            l_inner,
                            c_inner,
                            result,
                        });
                    }
                }).callback,
            };

            loop.start_watcher(w, c);
        }
    };
}

//NOTE:
//it look like i will FSEvents for apple systems
//I'm not sure how to integrate it into this system but is the
//best option when you need to watch a directory,
//if not you are kinda stuck to always receive write notifications

pub fn KqueueFsEvents(comptime xev: type) type {
    return struct {
        pub const FsEventError = error {
            Unexpected
        };

        pub const FsEvent = struct {
            delete: bool = false,
            write: bool = false,
            extend: bool = false,
            attrib: bool = false,
            rename: bool = false,
            revoke: bool = false,
        };

        const Self = @This();

        fd: posix.fd_t,
        path: [std.c.PATH_MAX]u8,
        len: usize,

        pub fn init(path: []const u8) !Self {
            const fd = try posix.open(
                path,
                .{ .EVTONLY = true },
                0,
            );


            var res = Self {
              .fd = fd,
              .path = undefined,
              .len = path.len
            };

            @memcpy(res.path[0..path.len], path);

            return res;
        }

        pub fn deinit(self: *Self) void {
            posix.close(self.fd);
        }

        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: FsEventError!FsEvent
            ) xev.CallbackAction,
        ) !void {
            loop.vnode(c, self.fd,
                std.c.NOTE.ATTRIB |
                std.c.NOTE.WRITE |
                std.c.NOTE.RENAME |
                std.c.NOTE.DELETE |
                std.c.NOTE.EXTEND |
                std.c.NOTE.REVOKE,
                userdata, (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    const result: FsEventError!FsEvent = blk: {
                        const fflags = r.vnode catch {
                            break :blk FsEventError.Unexpected;
                        };

                        var events: FsEvent = .{};
                        if (fflags & std.c.NOTE.DELETE != 0) events.delete = true;
                        if (fflags & std.c.NOTE.WRITE != 0) events.write = true;
                        if (fflags & std.c.NOTE.EXTEND != 0) events.extend = true;
                        if (fflags & std.c.NOTE.ATTRIB != 0) events.attrib = true;
                        if (fflags & std.c.NOTE.RENAME != 0) events.rename = true;
                        if (fflags & std.c.NOTE.REVOKE != 0) events.revoke = true;

                        break :blk events;
                    };

                    return @call(.always_inline, cb, .{
                        common.userdataValue(Userdata, ud),
                        l_inner,
                        c_inner,
                        result,
                    });
                }
            }).callback);
        }

        test {
            _ = FsEventsTests(xev, Self);

        }
    };
}

pub fn FsEventsDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        backend: Union,

        pub const Union = xev.Union(&.{"FsEvents"});
        pub const FsEventError = xev.ErrorSet(&.{"FsEvents", "FsEventError"});
        pub const FsEvent = struct {
            delete: bool = false,
            write: bool = false,
            extend: bool = false,
            attrib: bool = false,
            rename: bool = false,
            revoke: bool = false,
        };

        pub fn init(path: []const u8) !Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try api.FsEvents.init(path),
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

        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: FsEventError!FsEvent,
            ) xev.CallbackAction,
        ) !void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.FsEvents.FsEventError!api.FsEvents.FsEvent,
                        ) xev.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *xev.Loop.Union,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *xev.Completion.Union,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                if (r_inner) |fs_event|
                                    // Manually copy the fields of the FsEvent struct.
                                    // This is necessary because `api.FsEvents.FsEvent`
                                    // and `Self.FsEvent` are distinct types, even if
                                    // structurally identical.
                                    FsEvent{
                                        .delete = fs_event.delete,
                                        .write = fs_event.write,
                                        .extend = fs_event.extend,
                                        .attrib = fs_event.attrib,
                                        .rename = fs_event.rename,
                                        .revoke = fs_event.revoke,
                                    }
                                else |err|
                                    err, // xev.ErrorSet handles backend-specific errors transparently
                            );
                        }
                    }).callback;

                    try @field(
                        self.backend,
                        @tagName(tag),
                    ).wait(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = FsEventsTests(xev, Self);
        }
    };
}

fn FsEventsTests(comptime xev: type, comptime Impl: type) type {
    return struct {
        test "file events" {
            const testing = std.testing;
            testing.log_level = .debug;
            const fs = std.fs;

            const path = "kqueue_test_file";

            var file = try fs.cwd().createFile(path, .{});
            defer {
                file.close();
                fs.cwd().deleteFile(path) catch {};
            }

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init(path);
            defer notifier.deinit();

            const FsEventTest = struct {
                count: u32,
                event: Impl.FsEvent
            };

            var test_values =  FsEventTest{
                .count = 0,
                .event = undefined
            };

            var c_wait: xev.Completion = .{};

            try notifier.wait(&loop, &c_wait, FsEventTest, &test_values, (struct {
                fn callback(
                    ud: ?*FsEventTest,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.FsEventError!Impl.FsEvent,
                ) xev.CallbackAction {
                    const res = r catch unreachable;
                    ud.?.*.count += 1;
                    ud.?.*.event = res;

                    return .rearm;
                }
            }).callback);

            try loop.run(.no_wait);
            try testing.expectEqual(test_values.count, 0);
            try testing.expectEqual(test_values.event, undefined);

            _ = try file.write("First event");
            try loop.run(.no_wait);
            try testing.expectEqual(test_values.count, 1);
            try testing.expectEqual(test_values.event, Impl.FsEvent {
                .write = true,
                .extend = true,
            });

            try loop.run(.no_wait);
            try testing.expectEqual(test_values.count, 1);
            try testing.expectEqual(test_values.event, Impl.FsEvent {
                .write = true,
                .extend = true,
            });

            _ = try file.write("Second event");

            try loop.run(.once);
            try testing.expectEqual(test_values.count, 2);
            try testing.expectEqual(test_values.event, Impl.FsEvent {
                .write = true,
                .extend = true,
            });

            const new_path = "new_test_file";

            try fs.cwd().rename(path, new_path);
            try fs.cwd().rename(new_path, path);

            try loop.run(.once);
            try testing.expectEqual(test_values.count, 3);
            try testing.expectEqual(test_values.event, Impl.FsEvent {
                .rename = true
            });

            try loop.run(.once);
            try testing.expectEqual(test_values.count, 4);
            try testing.expectEqual(test_values.event, Impl.FsEvent {
                .attrib = true
            });

            try loop.run(.no_wait);
            try testing.expectEqual(test_values.count, 4);
            try testing.expectEqual(test_values.event, Impl.FsEvent {
                .attrib = true
            });
        }

        test "directory events" {
            const testing = std.testing;
            testing.log_level = .debug;
            const fs = std.fs;
            const Allocator = std.testing.allocator;

            const dir_path = "test_watch_dir_events";
            const file_in_dir_path = "test_watch_dir_events/test_file.txt";
            const renamed_file_in_dir_path = "test_watch_dir_events/renamed_test_file.txt";
            const sub_dir_path = "test_watch_dir_events/sub_dir";

            // Setup temporary directory
            try fs.cwd().makeDir(dir_path);
            defer fs.cwd().deleteTree(dir_path) catch {}; // Clean up recursively

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init(dir_path);
            defer notifier.deinit();

            const FsEventTest = struct {
                count: u32,
                events: std.ArrayList(Impl.FsEvent), // Use ArrayList to capture all events
            };

            var test_values = FsEventTest{
                .count = 0,
                .events = try std.ArrayList(Impl.FsEvent).initCapacity(Allocator, 0),
            };
            defer {
                test_values.events.deinit(Allocator);
            }

            var c_wait: xev.Completion = .{};

            try notifier.wait(&loop, &c_wait, FsEventTest, &test_values, (struct {
                fn callback(
                    ud: ?*FsEventTest,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.FsEventError!Impl.FsEvent,
                ) xev.CallbackAction {
                    const res = r catch unreachable;
                    ud.?.*.count += 1;
                    ud.?.*.events.append(Allocator, res) catch {
                        unreachable;
                    }; // Store all events
                    return .rearm;
                }
            }).callback);

            // Initial state: No events should be pending
            try loop.run(.no_wait);
            try testing.expectEqual(test_values.count, 0);

            // 1. Create a file in the directory
            var file = try fs.cwd().createFile(file_in_dir_path, .{});
            file.close();
            try loop.run(.no_wait); // Process one event
            try testing.expectEqual(test_values.events.items[0], Impl.FsEvent{.write = true});
            try testing.expectEqual(test_values.count, 1);

            // 3. Rename file within the directory
            try fs.cwd().rename(file_in_dir_path, renamed_file_in_dir_path);
            try loop.run(.no_wait); // Process one event
            try testing.expectEqual(test_values.count, 2);
            try testing.expectEqual(test_values.events.items[1], Impl.FsEvent{.write = true});

            // 4. Delete the file
            try fs.cwd().deleteFile(renamed_file_in_dir_path);
            try loop.run(.no_wait); // Process one event
            try testing.expectEqual(test_values.count, 3);
            try testing.expectEqual(test_values.events.items[2], Impl.FsEvent{.write = true});

            // 5. Create a subdirectory
            try fs.cwd().makeDir(sub_dir_path);
            try loop.run(.no_wait); // Process one event
            try testing.expectEqual(test_values.count, 4);
            try testing.expectEqual(test_values.events.items[3], Impl.FsEvent{.write = true});

            // 6. Delete the subdirectory
            try fs.cwd().deleteDir(sub_dir_path) ; // Ensure recursive delete
            try loop.run(.no_wait); // Process one event
            try testing.expectEqual(test_values.count, 5);
            try testing.expectEqual(test_values.events.items[4], Impl.FsEvent{.write = true});
        }
    };
}
