const std = @import("std");
const Listener = @import("server.zig").Listener;
const Config = @import("server.zig").Config;
const net = std.net;
const Kqueue = @import("kqueue.zig").Kqueue;
const Epoll = @import("epoll.zig").Epoll;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const address: net.Address = try net.Address.parseIp("127.0.0.1", 5882);

    const Loop = switch (@import("builtin").os.tag) {
        .macos => Kqueue,
        .linux => Epoll,
        else => @panic("platform not supported"),
    };

    const L = Listener(Loop);
    var listeners: [2]L = undefined;
    var threads: [2]std.Thread = undefined;

    for (&listeners, 0..) |_, id| {
        listeners[id] = try L.init(allocator, .{}, id);
        threads[id] = try std.Thread.spawn(.{}, L.run, .{ &listeners[id], address });
    }

    // TODO: shared global state to shutdown specific listener
    for (threads, 0..) |t, id| {
        t.join();
        listeners[id].deinit();
    }
}
