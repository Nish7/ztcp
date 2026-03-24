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
        listeners[id] = try Listener.init(allocator, 4096);
        threads[id] = try std.Thread.spawn(.{}, Listener.run, .{ &listeners[id], address });
    }

    // TODO: shared global state to shutdown specific listener
    for (threads, 0..) |t, id| {
        t.join();
        listeners[id].deinit();
    }
}
