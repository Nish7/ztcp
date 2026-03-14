const std = @import("std");
const Reader = @import("reader.zig").Reader;
const net = std.net;
const posix = std.posix;

pub const Client = struct {
    reader: Reader,
    socket: posix.socket_t,
    address: net.Address,

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t, address: std.net.Address) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        return .{ .reader = reader, .socket = socket, .address = address };
    }

    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.reader.deinit(allocator);
    }

    pub fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }
};
