const std = @import("std");
const Reader = @import("reader.zig").Reader;
const net = std.net;
const posix = std.posix;
const ClientList = @import("server.zig").ClientList;

pub const Client = struct {
    reader: Reader,
    socket: posix.socket_t,
    address: net.Address,
    read_timeout_node: *ClientNode,
    read_timeout: i64,

    allocator: std.mem.Allocator,
    write_buf: []u8,
    to_write: []u8,

    pub const ClientNode = struct {
        data: *Client,
        node: ClientList.Node = .{},
    };

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t, address: std.net.Address) !Client {
        var reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        const write_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(write_buffer);
        return .{
            .allocator = allocator,
            .reader = reader,
            .socket = socket,
            .address = address,
            .write_buf = write_buffer,
            .to_write = &.{},
            .read_timeout_node = undefined,
            .read_timeout = 0,
        };
    }

    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.reader.deinit(allocator);
        self.allocator.free(self.write_buf);
    }

    // write message from the msg to write_buf
    pub fn writeMessage(self: *Client, msg: []const u8) !bool {
        if (self.to_write.len > 0) {
            return error.PendingMessage;
        }

        if (msg.len + 4 > self.write_buf.len) return error.MessageTooLarge;
        std.mem.writeInt(u32, self.write_buf[0..4], @intCast(msg.len), .little);

        const end = msg.len + 4;
        @memcpy(self.write_buf[4..end], msg);
        self.to_write = self.write_buf[0..end];

        return self.write();
    }

    pub fn write(
        self: *Client,
    ) !bool {
        // write the message from to_write to client socket
        var buf = self.to_write;
        defer self.to_write = buf;

        while (buf.len > 0) {
            const n = posix.write(self.socket, buf) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return err,
            };

            if (n == 0) return error.Closed;
            buf = buf[n..];
        } else {
            return true;
        }
    }

    pub fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }
};
