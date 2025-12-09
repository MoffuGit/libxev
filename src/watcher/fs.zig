const inotify = @import("fs/inotify.zig");
const kqueue = @import("fs/kqueue.zig");
const std = @import("std");
const tree = @import("../tree.zig");
const double = @import("../queue_double.zig");

pub fn FileSystem(comptime xev: type) type {
    if (xev.dynamic) return struct {};
    return switch (xev.backend) {
        .io_uring,
        .epoll,
        => inotify.FileSystem(xev),
        .kqueue => kqueue.FileSystem(xev),
        else => struct {},
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

        pub fn watch(self: *Self, loop: *xev.Loop, path: []const u8, c: *Self.Completion, comptime Userdata: type, userdata: ?*Userdata, comptime cb: *const fn (
            ud: ?*Userdata,
            completion: *Self.Completion,
            result: u32,
        ) xev.CallbackAction) !void {
            switch (xev.backend) {
                inline else => |tag| {
                    try @field(
                        self.backend,
                        @tagName(tag),
                    ).watch(&@field(loop.backend, @tagName(tag)), path, c, Userdata, userdata, cb);
                },
            }
        }

        pub fn cancel(self: *Self, c: *Self.Completion) void {
            switch (xev.backend) {
                inline else => |tag| {
                    @field(
                        self.backend,
                        @tagName(tag),
                    ).cancel(c);
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
        completion: *T.Completion,
        result: u32,
    ) xev.CallbackAction;
}

pub fn NoopCallback(comptime xev: type, comptime T: type) Callback(xev, T) {
    return (struct {
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *T.Completion,
            _: u32,
        ) xev.CallbackAction {
            return .disarm;
        }
    }).noopCallback;
}

pub fn FileSystemTest(comptime xev: type) type {
    return struct {
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
                fn invoke(ud: ?*usize, _: *FS.Completion, _: u32) xev.CallbackAction {
                    ud.?.* += 1;
                    return .rearm;
                }
            }.invoke;

            var comp: FS.Completion = .{};

            try fs.watch(&loop, path1, &comp, usize, &counter, custom_callback);

            _ = try file.write("hello");
            try file.sync();

            // Run the event loop to process the inotify event
            _ = try loop.run(.no_wait);

            // Assert that the callback was invoked
            try testing.expectEqual(counter, 1);

            var counter2: usize = 0;

            var comp2: FS.Completion = .{};

            try fs.watch(&loop, path1, &comp2, usize, &counter2, custom_callback);

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
