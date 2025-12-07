const inotify = @import("fs/inotify.zig");
const kqueue = @import("fs/kqueue.zig");
const std = @import("std");
const tree = @import("../tree.zig");
const double = @import("../queue_double.zig");

pub fn FileSystem(comptime xev: type) type {
    if (xev.dynamic) unreachable;
    return switch (xev.backend) {
        .io_uring,
        .epoll,
        => inotify.FileSystem(xev),
        .kqueue => kqueue.FileSystem(xev),
        else => unreachable,
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
