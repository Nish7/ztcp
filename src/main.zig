const std = @import("std");
const Listener = @import("server.zig").Listener;
const net = std.net;
const posix = std.posix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address: net.Address = try net.Address.parseIp("127.0.0.1", 5882);
    var listeners: [2]Listener = undefined;
    var threads: [2]std.Thread = undefined;

    for (&listeners, 0..) |_, id| {
        var listener = try Listener.init(allocator, 4096);
        listeners[id] = listener;
        threads[id] = try std.Thread.spawn(.{}, Listener.run, .{ &listener, address });
    }

    for (threads) |t| {
        t.join();
    }
}
