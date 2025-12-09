const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const double = @import("../../queue_double.zig");
const tree = @import("../../tree.zig");
const pool = @import("../../pool.zig");
const fspkg = @import("../fs.zig");
const common = @import("../common.zig");
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
    return struct {
        const Callback = fspkg.Callback(xev, @This());
        const NoopCallback = fspkg.NoopCallback(xev, @This());

        pub const Completion = struct {
            next: ?*Completion = null,
            prev: ?*Completion = null,

            userdata: ?*anyopaque = null,

            callback: Callback = NoopCallback,

            wd: u32 = 0,

            flags: packed struct {
                state: State = .dead,
            } = .{},

            const State = enum(u1) {
                dead = 0,

                active = 1,
            };

            pub fn state(self: Completion) xev.CompletionState {
                return switch (self.flags.state) {
                    .dead => .dead,
                    .active => .active,
                };
            }

            pub fn invoke(self: *Completion, path: []const u8, res: u32) xev.CallbackAction {
                return self.callback(self.userdata, self, path, res);
            }
        };
        const FileWatcher = struct {
            const Self = @This();

            fd: i32 = -1,
            c: xev.Completion = .{},

            wd: u32,
            path: []const u8 = undefined,

            next: ?*FileWatcher = null,
            rb_node: tree.IntrusiveField(FileWatcher) = .{},
            completions: double.Intrusive(Completion) = .{},

            pub fn compare(a: *FileWatcher, b: *FileWatcher) std.math.Order {
                if (a.wd > b.wd) return .gt;
                if (a.wd < b.wd) return .lt;
                return .eq;
            }
        };
        const WatcherPool = pool.Intrusive(FileWatcher);
        buffer: [CAPACITY]FileWatcher = undefined,

        pool: WatcherPool = undefined,
        tree: tree.Intrusive(FileWatcher, FileWatcher.compare) = .{},
        flags: packed struct {
            init: bool = false,
        } = .{},

        const Self = @This();

        pub fn init() Self {
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

        pub fn watch(self: *Self, loop: *xev.Loop, path: []const u8, c: *Completion, comptime Userdata: type, userdata: ?*Userdata, comptime cb: *const fn (
            ud: ?*Userdata,
            completion: *Completion,
            path: []const u8,
            result: u32,
        ) xev.CallbackAction) !void {
            self.start();

            var temp: FileWatcher = .{ .wd = hash(path) };

            c.* = .{
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        completion: *Completion,
                        _path: []const u8,
                        result: u32,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{ common.userdataValue(Userdata, ud), completion, _path, result });
                    }
                }).callback,
                .userdata = userdata,
                .wd = temp.wd,
            };

            if (self.tree.find(&temp)) |w| {
                w.completions.push(c);
            } else {
                var w = try self.pool.alloc();
                w.* = .{ .fd = try posix.open(path, posix.O{}, 0), .wd = temp.wd, .path = path };

                w.c = .{
                    .op = .{
                        .vnode = .{
                            .fd = w.fd,
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

            c.flags.state = .active;
        }

        pub fn cancel(self: *Self, c: *Completion) void {
            var temp_wd = FileWatcher{ .wd = c.wd };

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
            const watcher: *FileWatcher = @ptrCast(@alignCast(ud.?));
            const vnode_flags = result.vnode catch |err| {
                log.err("Vnode event error for fd {}: {any}", .{ watcher.fd, err });
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
                const action = comp.invoke(watcher.path, vnode_flags);
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

            _ = try loop.run(.no_wait);

            const path1 = "test_path_1";
            const file = try std.fs.cwd().createFile(path1, .{});
            defer std.fs.cwd().deleteFile(path1) catch {};

            var counter: usize = 0;
            const custom_callback = struct {
                fn invoke(ud: ?*usize, _: *FS.Completion, path: []const u8, _: u32) xev.CallbackAction {
                    const cnt: *usize = @ptrCast(@alignCast(ud.?));
                    cnt.* += 1;
                    assert(std.mem.eql(u8, path1, path));
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Completion = .{};

            try fs.watch(&loop, path1, &comp, usize, &counter, custom_callback);

            _ = try loop.run(.no_wait);

            _ = try file.write("hello");
            try file.sync();

            _ = try loop.run(.once);

            try testing.expectEqual(counter, 1);

            var counter2: usize = 0;

            var comp2: FS.Completion = .{};

            try fs.watch(&loop, path1, &comp2, usize, &counter2, custom_callback);

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

            const dir_path = "test_directory_kqueue";
            try std.fs.cwd().makeDir(dir_path);
            defer std.fs.cwd().deleteDir(dir_path) catch {};

            const Event = struct { count: usize, flags: u32 };

            var event = Event{ .count = 0, .flags = 0 };
            const dir_callback_fn = struct {
                fn invoke(evt: ?*Event, _: *FS.Completion, path: []const u8, flags: u32) xev.CallbackAction {
                    evt.?.flags = flags;
                    evt.?.count += 1;
                    assert(std.mem.eql(u8, dir_path, path));
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Completion = .{};

            try fs.watch(&loop, dir_path, &comp, Event, &event, dir_callback_fn);
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

            const parent_dir_path = "test_parent_dir_kqueue_subdir";
            const sub_dir_path = parent_dir_path ++ "/test_subdir";
            const file_in_subdir_path = sub_dir_path ++ "/file_in_subdir.txt";

            try std.fs.cwd().makeDir(parent_dir_path);
            defer std.fs.cwd().deleteTree(parent_dir_path) catch {}; // Clean up parent and its contents

            const Event = struct { count: usize, flags: u32 };
            var event = Event{ .count = 0, .flags = 0 };

            const dir_callback_fn = struct {
                fn invoke(evt: ?*Event, _: *FS.Completion, path: []const u8, flags: u32) xev.CallbackAction {
                    evt.?.flags = flags;
                    assert(std.mem.eql(u8, parent_dir_path, path));
                    evt.?.count += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Completion = .{};

            // Watch the parent directory
            try fs.watch(&loop, parent_dir_path, &comp, Event, &event, dir_callback_fn);
            _ = try loop.run(.no_wait);

            // No events yet
            try testing.expectEqual(event.count, 0);

            // Create a subdirectory inside the watched parent directory
            // This should trigger a NOTE_WRITE event on parent_dir_path.
            try std.fs.cwd().makeDir(sub_dir_path);
            _ = try loop.run(.once);
            try testing.expectEqual(event.count, 1);
            try testing.expectEqual(event.flags, std.c.NOTE.WRITE | std.c.NOTE.LINK);

            // Reset flags for the next check
            event.flags = 0;

            // Create a file inside the subdirectory
            // Standard kqueue vnode watch on a directory typically does NOT recursively
            // watch subdirectories. Therefore, creating a file inside a subdirectory
            // should NOT trigger a new event on the parent_dir_path watcher.
            _ = try std.fs.cwd().createFile(file_in_subdir_path, .{});
            _ = try loop.run(.no_wait);

            // Expect count to remain 1, as no new event for parent_dir_path is expected
            // from changes within its subdirectories.
            try testing.expectEqual(event.count, 1);
            // Flags should still be 0 if no new event fired and it was reset.
            try testing.expectEqual(event.flags, 0);
        }
    };
}
