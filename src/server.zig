const std = @import("std");
const Client = @import("client.zig").Client;
const Epoll = @import("epoll.zig").Epoll;
const Kqueue = @import("kqueue.zig").Kqueue;
const ClientNode = Client.ClientNode;
const net = std.net;
const linux = std.os.linux;
const posix = std.posix;
const system = std.posix.system;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tcp_demo);

const READ_TIMEOUT = 60_000;
pub const ClientList = std.DoublyLinkedList;

pub const Event = union(enum) { accept: void, read: *Client, write: *Client, err: void, closed: void };

const Loop = switch (@import("builtin").os.tag) {
    .macos => Kqueue,
    .linux => Epoll,
    else => @panic("platform not supported"),
};

pub const Listener = struct {
    allocator: Allocator,
    connected: usize,
    max: usize,
    client_pool: std.heap.MemoryPool(Client),
    read_timeout_list: ClientList,
    client_node_pool: std.heap.MemoryPool(ClientNode),
    pending_free_list: []*Client,
    pending_count: usize = 0,
    poll: Loop,

    pub fn init(allocator: Allocator, max: usize) !Listener {
        const poll = try Loop.init();
        const client_free_list = try allocator.alloc(*Client, max);

        return .{
            .poll = poll,
            .max = max,
            .connected = 0,
            .allocator = allocator,
            .client_pool = std.heap.MemoryPool(Client).init(allocator),
            .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator),
            .read_timeout_list = .{},
            .pending_free_list = client_free_list,
        };
    }

    pub fn deinit(self: *Listener) void {
        self.poll.deinit();
        self.client_pool.deinit();
        self.client_node_pool.deinit();
        self.allocator.free(self.pending_free_list);
    }

    pub fn run(self: *Listener, address: std.net.Address) !void {
        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;

        const listener = try posix.socket(address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
            try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
        } else if (@hasDecl(posix.SO, "REUSEPORT")) {
            try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        }

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        try self.poll.addListener(listener);

        while (true) {
            const next_timeout = self.enforceTimeout();
            var it = try self.poll.wait(next_timeout);

            while (it.next()) |ready| {
                switch (ready) {
                    .accept => self.accept(listener) catch |err| log.err("failed to accept: {}", .{err}),
                    .read => |client| {
                        const msg = client.readMessage() catch |err| {
                            std.debug.print("read error: {any}", .{err});
                            self.removeClient(client);
                            break;
                        } orelse break;

                        std.debug.print("got: {s}\n", .{msg});

                        client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT;
                        self.read_timeout_list.remove(&(client.read_timeout_node.node));
                        self.read_timeout_list.append(&(client.read_timeout_node.node));

                        client.writeMessage(msg) catch |err| {
                            std.debug.print("write error: {any}", .{err});
                            self.removeClient(client);
                            break;
                        };

                        if (client.to_write.len > 0) break;
                    },
                    .write => |client| {
                        client.write() catch self.removeClient(client);
                    },
                    .err, .closed => continue,
                }
            }

            if (self.pending_count > 0) self.drainPendingClient();
        }
    }

    fn drainPendingClient(self: *Listener) void {
        for (self.pending_free_list[0..self.pending_count]) |c| {
            c.deinit(self.allocator);
            self.client_node_pool.destroy(c.read_timeout_node);
            self.client_pool.destroy(c);
        }

        self.pending_count = 0;
    }

    fn accept(self: *Listener, listener: posix.socket_t) !void {
        const available = self.max - self.connected;
        if (available <= 0) {
            std.debug.print("No space for available for client. Paused Accepting", .{});
            return;
        }

        for (0..available) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(
                listener,
                &address.any,
                &address_len,
                posix.SOCK.NONBLOCK,
            ) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client: *Client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);

            client.* = Client.init(
                self.allocator,
                socket,
                address,
                &self.poll,
            ) catch |err| {
                log.err("failed to initialize client: {}", .{err});
                posix.close(socket);
                self.client_pool.destroy(client);
                return;
            };

            client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT;
            client.read_timeout_node = try self.client_node_pool.create();
            errdefer self.client_node_pool.destroy(client.read_timeout_node);

            client.read_timeout_node.data = client;
            self.read_timeout_list.append(&(client.read_timeout_node.node));
            errdefer self.read_timeout_list.remove(&(client.read_timeout_node.node));

            try self.poll.newClient(client);
            self.connected += 1;
        }
    }

    fn enforceTimeout(self: *Listener) i32 {
        const now = std.time.milliTimestamp();
        var node = self.read_timeout_list.first;

        while (node) |n| : (node = n.next) {
            const l: *ClientNode = @fieldParentPtr("node", n);
            const client = l.data;
            const diff = client.read_timeout - now;
            if (diff > 0) return @intCast(diff);
            posix.shutdown(client.socket, .recv) catch {};
        } else {
            return -1;
        }
    }

    fn removeClient(self: *Listener, client: *Client) void {
        if (client.closed) return;

        posix.close(client.socket);
        client.closed = true;

        self.pending_free_list[self.pending_count] = client;
        self.pending_count += 1;

        self.read_timeout_list.remove(&(client.read_timeout_node.node));

        self.connected -= 1;

        std.debug.print("[{f}] Client Removed!\n", .{client.address});
    }
};
