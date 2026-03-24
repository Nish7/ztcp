const std = @import("std");
const Client = @import("client.zig").Client;
const Event = @import("server.zig").Event;
const linux = std.os.linux;
const posix = std.posix;
const system = std.posix.system;

pub const Kqueue = struct {
    kfd: posix.fd_t,
    event_list: [128]system.Kevent = undefined,
    change_list: [16]system.Kevent = undefined,
    change_count: usize = 0,

    pub fn init() !Kqueue {
        const kfd = try posix.kqueue();
        return .{ .kfd = kfd };
    }

    pub fn deinit(self: *Kqueue) void {
        posix.close(self.kfd);
    }

    pub fn wait(self: *Kqueue, timeout_ms: i32) !Iterator {
        const timeout = posix.timespec{
            .sec = @intCast(@divTrunc(timeout_ms, 1000)),
            .nsec = @intCast(@mod(timeout_ms, 1000) * 1000000),
        };

        const count = try posix.kevent(self.kfd, self.change_list[0..self.change_count], &self.event_list, &timeout);
        self.change_count = 0;
        return .{ .index = 0, .ready_list = self.event_list[0..count] };
    }

    const Iterator = struct {
        index: usize,
        ready_list: []system.Kevent,

        pub fn next(self: *Iterator) ?Event {
            if (self.index == self.ready_list.len) return null;

            self.index += 1;
            const ready = self.ready_list[self.index];

            switch (ready.udata) {
                0 => return .{ .accept = {} },
                else => |nptr| {
                    const client: *Client = @ptrFromInt(nptr);
                    if (client.closed) return .{ .closed = {} };
                    if (ready.flags & posix.system.EV.ERROR != 0) return .{ .err = {} };
                    if (ready.filter == system.EVFILT.READ) return .{ .read = client };
                    if (ready.filter == system.EVFILT.WRITE) return .{ .write = client };
                },
            }

            return null;
        }
    };

    pub fn addListener(self: *Kqueue, listener: posix.socket_t) !void {
        // ok to use EV.ADD to renable the listener if it was previous
        // disabled via removeListener
        try self.queueChange(.{
            .ident = @intCast(listener),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
    }

    pub fn removeListener(self: *Kqueue, listener: posix.socket_t) !void {
        try self.queueChange(.{
            .ident = @intCast(listener),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
    }

    pub fn newClient(self: *Kqueue, client: *Client) !void {
        try self.queueChange(.{
            .ident = @intCast(client.socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(client),
        });

        try self.queueChange(.{
            .ident = @intCast(client.socket),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.ADD | posix.system.EV.DISABLE | posix.system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(client),
        });
    }

    pub fn readMode(self: *Kqueue, client: *Client) !void {
        try self.queueChange(.{
            .ident = @intCast(client.socket),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });

        try self.queueChange(.{
            .ident = @intCast(client.socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(client),
        });
    }

    pub fn writeMode(self: *Kqueue, client: *Client) !void {
        try self.queueChange(.{
            .ident = @intCast(client.socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });

        try self.queueChange(.{
            .ident = @intCast(client.socket),
            .flags = posix.system.EV.ENABLE,
            .filter = posix.system.EVFILT.WRITE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(client),
        });
    }

    pub fn queueChange(self: *Kqueue, event: system.Kevent) !void {
        var count = self.change_count;
        if (count == self.change_list.len) {
            _ = try posix.kevent(self.kfd, &self.change_list, &.{}, null);
            count = 0;
        }

        self.change_list[count] = event;
        self.change_count = count + 1;
    }
};
