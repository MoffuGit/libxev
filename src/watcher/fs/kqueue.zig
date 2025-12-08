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
    const CallbackAction = xev.CallbackAction;
    const FSCompletion = fspkg.FSCompletion(xev);

    return struct {
        pub const FileWatcher = fspkg.FileWatcher(xev);
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

        pub fn watch(self: *Self, loop: *xev.Loop, path: []const u8, c: *FSCompletion, comptime Userdata: type, userdata: ?*Userdata, comptime cb: *const fn (
            ud: ?*Userdata,
            completion: *FSCompletion,
            result: u32,
        ) CallbackAction) !void {
            self.start();

            var temp: FileWatcher = .{ .wd = hash(path) };

            c.* = .{
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        completion: *FSCompletion,
                        result: u32,
                    ) CallbackAction {
                        return @call(.always_inline, cb, .{ common.userdataValue(Userdata, ud), completion, result });
                    }
                }).callback,
                .userdata = userdata,
                .wd = temp.wd,
            };

            if (self.tree.find(&temp)) |w| {
                w.completions.push(c);
            } else {
                var w = try self.pool.alloc();
                w.fd = try posix.open(path, posix.O{}, 0);
                w.wd = temp.wd;

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

        pub fn cancel(self: *Self, c: *FSCompletion) void {
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

pub fn FileSystemTest(comptime xev: type) type {
    const CallbackAction = xev.CallbackAction;
    const FSCompletion = fspkg.FSCompletion(xev);

    return struct {
        const testing = std.testing;
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
                fn invoke(ud: ?*usize, _: *FSCompletion, _: u32) CallbackAction {
                    const cnt: *usize = @ptrCast(@alignCast(ud.?));
                    cnt.* += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FSCompletion = .{};

            try fs.watch(&loop, path1, &comp, usize, &counter, custom_callback);

            _ = try loop.run(.no_wait);

            _ = try file.write("hello");
            try file.sync();

            _ = try loop.run(.once);

            try testing.expectEqual(counter, 1);

            var counter2: usize = 0;

            var comp2: FSCompletion = .{};

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
                fn invoke(evt: ?*Event, _: *FSCompletion, flags: u32) CallbackAction {
                    evt.?.flags = flags;
                    evt.?.count += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FSCompletion = .{};

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
    };
}
