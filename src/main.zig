const std = @import("std");
const Server = @import("server.zig").Server;
const net = std.net;
const posix = std.posix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var server = try Server.init(allocator, 4096);

    const address: net.Address = try net.Address.parseIp("127.0.0.1", 5882);
    try server.run(address);
    defer server.deinit();
}
