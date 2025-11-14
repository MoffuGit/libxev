const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const common = @import("common.zig");
const linux = std.os.linux; // Only for fanotify

/// File system event watcher. This allows you to observe changes to files
/// and directories.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub fn FSEvents(comptime xev: type) type {
    if (xev.dynamic) return FSEventsDynamic(xev);

    return switch (xev.backend) {
        .io_uring => FSEventsFanotify(xev),
        .kqueue => FSEventsKqueue(xev),
        // Add other backends later if supported
        else => struct {}, // Noop for unsupported backends
    };
}

/// Generic types of file system events that can be observed.
pub const FSEventType = enum {
    /// File content modified.
    modify,
    /// File or directory deleted.
    delete,
    /// File or directory attributes changed (e.g., permissions, timestamp).
    attrib,
    /// File or directory created.
    create,
    /// File or directory renamed.
    rename,
    /// An unknown or unmapped event occurred.
    unknown,
};

/// Options for configuring what types of file system events to watch for.
pub const FSEventOptions = packed struct {
    modify: bool = false,
    delete: bool = false,
    attrib: bool = false,
    create: bool = false,
    rename: bool = false,
};

pub const FSEventError = error{
    MissingThreadpool,
    UnsupportedOperation,
    PathNotFound,
    Canceled,
    MissingKevent,
    Unexpected,
} || posix.FanotifyMarkError || posix.FanotifyInitError || posix.KEventError;

/// FSEvents implementation using fanotify (Linux).
fn FSEventsFanotify(comptime xev: type) type {
    const linux_fan = std.os.linux;

    return struct {
        const Self = @This();

        fanotify_fd: posix.fd_t,
        target_path: []const u8,
        event_buffer: [1024]u8, // Buffer for fanotify events
        completion: xev.Completion, // Completion for reading fanotify events on thread pool

        pub fn init(path: []const u8, options: FSEventOptions) !Self {
            if (xev.Loop.threaded == false) {
                // Fanotify read operation requires a thread pool because it's a blocking read.
                return error.MissingThreadpool;
            }

            const fanotify_fd = try posix.fanotify_init(
                .{ .CLOEXEC = true, .NONBLOCK = true },
                0, // Event flags for init, usually 0
            );
            errdefer posix.close(fanotify_fd);

            // Translate generic options to fanotify flags
            var event_flags: linux_fan.FAN_EVENT = .{};
            if (options.modify) event_flags.MODIFY = true;
            if (options.delete) event_flags.DELETE = true;
            if (options.attrib) event_flags.ATTRIB = true;
            if (options.create) event_flags.CREATE = true;
            if (options.rename) event_flags.MOVED_FROM = true;
            if (options.rename) event_flags.MOVED_TO = true;

            // Mark the path for watching. Watching both files and directories.
            try linux_fan.fanotify_mark(
                fanotify_fd,
                .{ .FILE = true, .DIR = true, .MOUNT = true }, // Mark files, dirs and mount points
                event_flags,
                posix.AT.FDCWD, // Watch relative to current working directory
                path,
            );

            return .{
                .fanotify_fd = fanotify_fd,
                .target_path = path,
                .event_buffer = undefined,
                .completion = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            posix.close(self.fanotify_fd);
        }

        pub fn watch(
            self: *Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn(
                event_type: FSEventType,
                path: []const u8,
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: FSEventError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .fanotify = .{
                        .fd = self.fanotify_fd,
                        .buffer = .{ .slice = &self.event_buffer },
                    },
                },
                .flags = .{ .threadpool = true }, // Must run on thread pool
                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud_inner: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const self_ptr: *Self = @fieldParentPtr("completion", c_inner);
                        var action: xev.CallbackAction = .disarm;

                        if (r.fanotify) |bytes_read| {
                            var offset: usize = 0;
                            while (offset < bytes_read) : (offset += linux_fan.fanotify_event_len(@ptrCast(&self_ptr.event_buffer[offset]))) {
                                const event_metadata: *linux_fan.fanotify_event_metadata = @ptrCast(&self_ptr.event_buffer[offset]);
                                const event_path = linux_fan.fanotify_event_path(event_metadata);

                                // Map fanotify flags to generic FSEventType enum
                                const event_type = if (event_metadata.mask & linux_fan.FAN.MODIFY > 0) FSEventType.modify
                                else if (event_metadata.mask & linux_fan.FAN.DELETE > 0) FSEventType.delete
                                else if (event_metadata.mask & linux_fan.FAN.ATTRIB > 0) FSEventType.attrib
                                else if (event_metadata.mask & linux_fan.FAN.CREATE > 0) FSEventType.create
                                else if (event_metadata.mask & linux_fan.FAN.MOVED_FROM > 0 or event_metadata.mask & linux_fan.FAN.MOVED_TO > 0) FSEventType.rename
                                else FSEventType.unknown;

                                action = @call(.always_inline, cb, .{
                                    event_type,
                                    event_path,
                                    common.userdataValue(Userdata, ud_inner),
                                    l_inner,
                                    c_inner,
                                    .{}, // Success
                                });
                                if (action == .disarm) break; // If user disarms, stop processing events in this batch
                            }
                        } else |err| {
                            action = @call(.always_inline, cb, .{
                                FSEventType.unknown, // Default event type for error reporting
                                self_ptr.target_path,
                                common.userdataValue(Userdata, ud_inner),
                                l_inner,
                                c_inner,
                                err,
                            });
                        }

                        if (action == .rearm) {
                             // Re-queue the read operation for subsequent events
                            l_inner.add(c_inner);
                            return .disarm;
                        }
                        return action;
                    }
                }).callback,
            };
            loop.add(c);
        }
    };
}

/// FSEvents implementation using kqueue EVFILT_VNODE (macOS, FreeBSD).
fn FSEventsKqueue(comptime xev: type) type {
    return struct {
        const Self = @This();

        // kqueue vnode operations are per-file descriptor.
        target_fd: posix.fd_t,
        target_path: []const u8, // Path being watched (for callback info)

        pub fn init(path: []const u8, options: FSEventOptions) !Self {
            // Open the file/directory to get its file descriptor.
            // This is required for kqueue VNODE filter.
            // Using a simple openFile, assuming read-only access for watching.
            // Flags must be translated to kqueue NOTE_* flags
            var vnode_flags: u32 = 0;
            if (options.modify) vnode_flags |= (std.c.NOTE.WRITE | std.c.NOTE.EXTEND);
            if (options.delete) vnode_flags |= std.c.NOTE.DELETE;
            if (options.attrib) vnode_flags |= std.c.NOTE.ATTRIB;
            if (options.create) vnode_flags |= std.c.NOTE.LINK; // New link means creation
            if (options.rename) vnode_flags |= std.c.NOTE.RENAME;

            if (vnode_flags == 0) {
                 return error.UnsupportedOperation; // Must provide at least one watch flag
            }

            // Attempt to open the file/directory. If it's a directory, openDir is more appropriate.
            // For simplicity, using openFile with default options and assuming it works for both.
            // In a real scenario, you'd want to handle directory vs. file opening carefully.
            const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                if (err == error.FileNotFound) return error.PathNotFound;
                return err;
            };
            errdefer file.close();

            return .{
                .target_fd = file.handle,
                .target_path = path,
            };
        }

        pub fn deinit(self: *Self) void {
            posix.close(self.target_fd); // Close the watched FD
        }

        pub fn watch(
            self: *Self,
            loop: *xev.Loop,
            c: *xev.Completion, // The completion for this specific watch call
            options: FSEventOptions,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn(
                event_type: FSEventType,
                path: []const u8,
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: FSEventError!void,
            ) xev.CallbackAction,
        ) void {
            // Translate generic options to kqueue NOTE_* flags
            var vnode_flags: u32 = 0;
            if (options.modify) vnode_flags |= (std.c.NOTE.WRITE | std.c.NOTE.EXTEND);
            if (options.delete) vnode_flags |= std.c.NOTE.DELETE;
            if (options.attrib) vnode_flags |= std.c.NOTE.ATTRIB;
            if (options.create) vnode_flags |= std.c.NOTE.LINK;
            if (options.rename) vnode_flags |= std.c.NOTE.RENAME;

            assert(vnode_flags != 0); // Must provide kqueue flags

            c.* = .{
                .op = .{
                    .vnode = .{
                        .fd = self.target_fd,
                        .flags = vnode_flags,
                    },
                },
                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud_inner: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const self_ptr: *Self = @alignCast(@fieldParentPtr("target_fd", &c_inner.op.vnode.fd));
                        var action: xev.CallbackAction = .disarm;

                        if (r.vnode) |ev_flags| {
                            // Map kqueue vnode flags to generic FSEventType enum
                            const event_type = if (ev_flags & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND) > 0) FSEventType.modify
                            else if (ev_flags & std.c.NOTE.DELETE > 0) FSEventType.delete
                            else if (ev_flags & std.c.NOTE.ATTRIB > 0) FSEventType.attrib
                            else if (ev_flags & std.c.NOTE.LINK > 0) FSEventType.create
                            else if (ev_flags & std.c.NOTE.RENAME > 0) FSEventType.rename
                            else FSEventType.unknown;

                            action = @call(.always_inline, cb, .{
                                event_type,
                                self_ptr.target_path, // Use stored path
                                common.userdataValue(Userdata, ud_inner),
                                l_inner,
                                c_inner,
                                {},
                            });
                        } else |err| {
                            action = @call(.always_inline, cb, .{
                                FSEventType.unknown, // Default event type for error reporting
                                self_ptr.target_path,
                                common.userdataValue(Userdata, ud_inner),
                                l_inner,
                                c_inner,
                                err,
                            });
                        }
                        if (action == .rearm) {
                            // Re-queue the vnode watch for subsequent events
                            l_inner.add(c_inner);
                            return .disarm;
                        }
                        return action;
                    }
                }).callback,
            };
            loop.add(c);
        }

        test {
            _ = FSEventsTests(xev, Self);
        }
    };
}

/// Dynamic FSEvents implementation for dynamic backend selection.
fn FSEventsDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        backend: Union,

        pub const Union = xev.Union(&.{ "FSEvents" });

        pub fn init(path: []const u8, options: FSEventOptions) !Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try @field(api, "FSEvents").init(path, options),
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

        pub fn watch(
            self: *Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            options: FSEventOptions,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn(
                event_type: FSEventType,
                path: []const u8,
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: FSEventError!void,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            event_type_inner: FSEventType,
                            path_inner: []const u8,
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: @field(api, "FSEvents").WatchError!void,
                        ) xev.CallbackAction {
                            return cb(
                                event_type_inner,
                                path_inner,
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *xev.Loop.Union,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *xev.Completion.Union,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).watch(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        options,
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = FSEventsTests(xev, Self);
        }
    };
}

// Tests (adapted from kqueue.zig and io_uring.zig examples)
fn FSEventsTests(
    comptime xev: type,
    comptime Impl: type,
) type {
    return struct {
        test "fsevents: kqueue delete" {
            if (builtin.os.tag != .macos and builtin.os.tag != .freebsd) return error.SkipZigTest;

            const testing = std.testing;
            const fs = std.fs;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            // Create a temporary file to watch
            const file_path = "test_fsevents_kqueue_file_delete";
            var file = try fs.cwd().createFile(file_path, .{});
            defer fs.cwd().deleteFile(file_path) catch {}; // Ensure cleanup even if init fails

            var fs_watcher = try Impl.init(file_path, .{ .delete = true, .create = true });
            defer fs_watcher.deinit();

            var received_event: ?FSEventType = null;
            var c: xev.Completion = .{};

            fs_watcher.watch(&loop, &c, .{ .delete = true, .create = true }, ?FSEventType, &received_event, (struct {
                fn callback(
                    event_type: FSEventType,
                    path: []const u8,
                    ud: ?*?FSEventType,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.FSEventError!void,
                ) xev.CallbackAction {
                    _ = path;
                    _ = r catch unreachable;
                    const event_ptr: *?FSEventType = @ptrCast(@alignCast(ud.?));
                    event_ptr.* = event_type;
                    return .disarm;
                }
            }).callback);

            // Initial tick to submit the event to kqueue
            try loop.run(.no_wait);
            try testing.expect(c.state() == .active); // One active event

            file.close(); // Close the file, then delete it.
            try fs.cwd().deleteFile(file_path);

            // Run the loop until the event is processed
            try loop.run(.until_done);

            try testing.expectEqual(FSEventType.delete, received_event.?);
            try testing.expect(c.state() == .dead);
        }

        test "fsevents: kqueue write" {
            if (builtin.os.tag != .macos and builtin.os.tag != .freebsd) return error.SkipZigTest;

            const testing = std.testing;
            const fs = std.fs;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            // Create a temporary file to watch
            const file_path = "test_fsevents_kqueue_file_write";
            var file = try fs.cwd().createFile(file_path, .{});
            defer file.close();
            defer fs.cwd().deleteFile(file_path) catch {};

            var fs_watcher = try Impl.init(file_path, .{ .modify = true });
            defer fs_watcher.deinit();

            var received_event: ?FSEventType = null;
            var c: xev.Completion = .{};

            fs_watcher.watch(&loop, &c, .{ .modify = true }, ?FSEventType, &received_event, (struct {
                fn callback(
                    event_type: FSEventType,
                    path: []const u8,
                    ud: ?*?FSEventType,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.FSEventError!void,
                ) xev.CallbackAction {
                    _ = path;
                    _ = r catch unreachable;
                    const event_ptr: *?FSEventType = @ptrCast(@alignCast(ud.?));
                    event_ptr.* = event_type;
                    return .disarm;
                }
            }).callback);

            // Initial tick to submit the event to kqueue
            try loop.run(.no_wait);
            try testing.expect(c.state() == .active);

            // Trigger the NOTE_WRITE event by writing to the file
            const content = "hello world";
            try file.writeAll(content);
            try file.sync(); // Ensure write is flushed to disk

            // Run the loop until the event is processed
            try loop.run(.until_done);

            // Verify the callback was triggered with the correct flags
            try testing.expectEqual(FSEventType.modify, received_event.?);
            try testing.expect(c.state() == .dead);
        }

        test "fsevents: fanotify modify" {
            if (builtin.os.tag != .linux) return error.SkipZigTest;

            const testing = std.testing;
            const fs = std.fs;

            var tpool = xev.ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create a temporary file to watch
            const file_path = "test_fsevents_fanotify_file_modify";
            var file = try fs.cwd().createFile(file_path, .{});
            defer file.close();
            defer fs.cwd().deleteFile(file_path) catch {};

            var fs_watcher = try Impl.init(file_path, .{ .modify = true });
            defer fs_watcher.deinit();

            var received_event: ?FSEventType = null;
            var c: xev.Completion = .{};

            fs_watcher.watch(&loop, &c, .{ .modify = true }, ?FSEventType, &received_event, (struct {
                fn callback(
                    event_type: FSEventType,
                    path: []const u8,
                    ud: ?*?FSEventType,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WatchError!void,
                ) xev.CallbackAction {
                    _ = path;
                    _ = r catch unreachable;
                    const event_ptr: *?FSEventType = @ptrCast(@alignCast(ud.?));
                    event_ptr.* = event_type;
                    return .disarm;
                }
            }).callback);

            // Initial tick to submit the event
            try loop.run(.no_wait);
            try testing.expect(c.state() == .active);

            // Trigger the event (modify the file)
            const content = "hello world";
            _ = try file.writeAll(content);
            _ = try file.sync(); // Ensure write is flushed to disk

            try loop.run(.until_done);

            // Verify the callback was triggered and bytes were read
            try testing.expectEqual(FSEventType.modify, received_event.?);
            try testing.expect(c.state() == .dead);
        }

        test "fsevents: fanotify create/delete directory" {
            if (builtin.os.tag != .linux) return error.SkipZigTest;

            const testing = std.testing;
            const fs = std.fs;

            var tpool = xev.ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create a temporary directory to watch
            const dir_path = "test_fsevents_fanotify_dir_v2";
            try fs.cwd().makeDir(dir_path);
            defer fs.cwd().deleteDir(dir_path) catch {};

            var fs_watcher = try Impl.init(dir_path, .{ .create = true, .delete = true });
            defer fs_watcher.deinit();

            var received_event: ?FSEventType = null;
            var c: xev.Completion = .{};

            fs_watcher.watch(&loop, &c, .{ .create = true, .delete = true }, ?FSEventType, &received_event, (struct {
                fn callback(
                    event_type: FSEventType,
                    path: []const u8,
                    ud: ?*?FSEventType,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WatchError!void,
                ) xev.CallbackAction {
                    _ = path;
                    _ = r catch unreachable;
                    const event_ptr: *?FSEventType = @ptrCast(@alignCast(ud.?));
                    event_ptr.* = event_type;
                    return .disarm;
                }
            }).callback);

            // Initial tick to submit the event
            try loop.run(.no_wait);
            try testing.expect(c.state() == .active);

            // Create a file inside the watched directory
            const file_path = std.fmt.allocPrint(testing.allocator, "{s}/new_file_v2.txt", .{dir_path}) catch unreachable;
            defer testing.allocator.free(file_path);
            var new_file = try fs.cwd().createFile(file_path, .{});
            new_file.close();

            try loop.run(.until_done);
            try testing.expectEqual(FSEventType.create, received_event.?);
            received_event = null; // Reset for next event
            try loop.run(.no_wait); // Ensure no more events immediately

            // Delete the file
            try fs.cwd().deleteFile(file_path);
            try loop.run(.until_done);
            try testing.expectEqual(FSEventType.delete, received_event.?);
            try testing.expect(c.state() == .dead);
        }
    };
}
