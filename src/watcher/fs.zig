const inotify = @import("fs/inotify.zig");
const std = @import("std");

pub fn FileSystem(comptime xev: type) type {
    if (xev.dynamic) unreachable;
    return switch (xev.backend) {
        .io_uring,
        .epoll,
        => inotify.FileSystem(xev),
        else => unreachable,
    };
}

pub fn Callback(comptime T: type) type {
    return *const fn (
        userdata: ?*anyopaque,
        completion: *T.Completion,
        result: u32,
    ) CallbackAction;
}

pub fn NoopCallback(comptime T: type) Callback(T) {
    return (struct {
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *T.Completion,
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
