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
        else => unreachable,
    };
}

fn FileSystemDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        pub const Union = xev.Union(&.{"FileSystem"});

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

        pub fn watch(self: *Self, loop: *xev.Loop, path: []const u8, c: *Completion) !void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    try @field(
                        self.backend,
                        @tagName(tag),
                    ).watch(
                        &@field(loop.backend, @tagName(tag)),
                        path,
                        &@field(c.value, @tagName(tag)),
                    );
                },
            }
        }

        pub fn cancel(self: *Self, c: *Completion) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).cancel(
                        &@field(c.value, @tagName(tag)),
                    );
                },
            }
        }

        test {
            _ = FileSystemTest(xev, Self);
        }
    };
}

pub fn FileWatcher(comptime xev: type) type {
    return switch (xev.backend) {
        .io_uring,
        .epoll,
        => struct {
            const Self = @This();

            wd: u32,

            next: ?*Self = null,
            rb_node: tree.IntrusiveField(Self) = .{},
            completions: double.Intrusive(Completion) = .{},

            pub fn compare(a: *Self, b: *Self) std.math.Order {
                if (a.wd > b.wd) return .gt;
                if (a.wd < b.wd) return .lt;
                return .eq;
            }
        },
        .kqueue => struct {
            const Self = @This();

            fd: i32 = -1,
            c: xev.Completion = .{},

            wd: u32,

            next: ?*Self = null,
            rb_node: tree.IntrusiveField(Self) = .{},
            completions: double.Intrusive(Completion) = .{},

            pub fn compare(a: *Self, b: *Self) std.math.Order {
                if (a.wd > b.wd) return .gt;
                if (a.wd < b.wd) return .lt;
                return .eq;
            }
        },
        else => unreachable,
    };
}

pub const Completion = struct {
    next: ?*Completion = null,
    prev: ?*Completion = null,

    userdata: ?*anyopaque = null,

    callback: Callback() = NoopCallback(),

    wd: u32 = 0,

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

pub fn Callback() type {
    return *const fn (
        userdata: ?*anyopaque,
        completion: *Completion,
        result: u32,
    ) CallbackAction;
}

pub fn NoopCallback() Callback() {
    return (struct {
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *Completion,
            _: u32,
        ) CallbackAction {
            return .disarm;
        }
    }).noopCallback;
}

pub const CallbackAction = enum(c_int) {
    disarm = 0,

    rearm = 1,
};

pub const CompletionState = enum(c_int) {
    dead = 0,

    active = 1,
};

pub fn FileSystemTest(comptime xev: type) type {
    return struct {
        const testing = std.testing;
        const FS = FileSystem(xev);

        test "test dynamic file system watcher" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var fs = try FS.init();
            defer fs.deinit();

            // const path1 = "test_path_1";
            // _ = try std.fs.cwd().createFile(path1, .{});
            // defer std.fs.cwd().deleteFile(path1) catch {};
            // var comp1_1: Completion = .{};
            // var comp1_2: Completion = .{};
            // var comp1_3: Completion = .{};
            //
            // try fs.watch(&loop, path1, &comp1_1);
            // try fs.watch(&loop, path1, &comp1_2);
            // try fs.watch(&loop, path1, &comp1_3);
            //
            // const path2 = "test_path_2";
            // const path3 = "test_path_3";
            // var comp2_1: Completion = .{};
            // var comp3_1: Completion = .{};
            //
            // _ = try std.fs.cwd().createFile(path2, .{});
            // defer std.fs.cwd().deleteFile(path2) catch {};
            // _ = try std.fs.cwd().createFile(path3, .{});
            // defer std.fs.cwd().deleteFile(path3) catch {};
            //
            // try fs.watch(&loop, path2, &comp2_1);
            // try fs.watch(&loop, path3, &comp3_1);
            //
            // const path4 = "test_path_4";
            // const path5 = "test_path_5";
            // _ = try std.fs.cwd().createFile(path4, .{});
            // defer std.fs.cwd().deleteFile(path4) catch {};
            // _ = try std.fs.cwd().createFile(path5, .{});
            // defer std.fs.cwd().deleteFile(path5) catch {};
            // var comp4_1: Completion = .{};
            // var comp4_2: Completion = .{};
            // var comp5_1: Completion = .{};
            // var comp5_2: Completion = .{};
            // var comp5_3: Completion = .{};
            //
            // try fs.watch(&loop, path4, &comp4_1);
            // try fs.watch(&loop, path4, &comp4_2);
            // try fs.watch(&loop, path5, &comp5_1);
            // try fs.watch(&loop, path5, &comp5_2);
            // try fs.watch(&loop, path5, &comp5_3);
            //
            // try testing.expectEqual(fs.pool.countFree(), 95);
            //
            // fs.cancel(&comp4_1);
            // fs.cancel(&comp4_2);
            // fs.cancel(&comp5_1);
            // fs.cancel(&comp5_2);
            // fs.cancel(&comp5_3);
            //
            // try testing.expectEqual(fs.pool.countFree(), 97);
        }
    };
}
