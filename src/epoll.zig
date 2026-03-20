const std = @import("std");
const Client = @import("client.zig").Client;
const linux = std.os.linux;
const posix = std.posix;

pub const Epoll = struct {
    efd: posix.fd_t,
    ready_list: [128]linux.epoll_event = undefined,

    pub fn init() !Epoll {
        const efd = try posix.epoll_create1(0);
        return .{ .efd = efd };
    }

    pub fn deinit(self: Epoll) void {
        posix.close(self.efd);
    }

    pub fn wait(self: *Epoll, timeout: i32) []linux.epoll_event {
        const count = posix.epoll_wait(self.efd, &self.ready_list, timeout);
        return self.ready_list[0..count];
    }

    pub fn addListener(self: Epoll, listener: posix.socket_t) !void {
        var event = linux.epoll_event{
            .data = .{ .ptr = 0 },
            .events = linux.EPOLL.IN,
        };

        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, listener, &event);
    }


    pub fn removeListener(self: Epoll, listener: posix.socket_t) !void {
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_DEL, listener, null);
    }

    pub fn newClient(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };

        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, client.socket, &event);
    }

    pub fn readMode(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };

        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }

    pub fn writeMode(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.OUT,
            .data = .{ .ptr = @intFromPtr(client) },
        };

        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }
};
