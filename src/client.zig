const std = @import("std");
const Reader = @import("reader.zig").Reader;
const net = std.net;
const posix = std.posix;

pub const Client = struct {
    socket: posix.socket_t,
    address: net.Address,

    pub fn handle(self: Client) void {
        self._handle() catch |err| switch (err) {
            error.Closed => {},
            else => std.debug.print("[{f} client handle error: {}]\n", .{ self.address, err }),
        };
    }

    pub fn _handle(self: Client) !void {
        defer posix.close(self.socket);

        std.debug.print("{f} connected!\n", .{self.address});

        const timeout = posix.timeval{ .sec = 20, .usec = 500_000 };
        try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        var buf: [1024]u8 = undefined;
        var reader = Reader{ .buf = &buf, .socket = self.socket };

        while (true) {
            const msg = try reader.readMessage();
            std.debug.print("Got: {s}\n", .{msg});
        }
    }
};
