const std = @import("std");
const Client = @import("client.zig").Client;
const Epoll = @import("epoll.zig").Epoll;
const Kqueue = @import("kqueue.zig").Kqueue;
const ClientNode = Client.ClientNode;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tcp_demo);

pub const ClientList = std.DoublyLinkedList;

pub const Config = struct {
    max_clients: usize = 4096,
    read_timeout_ms: i64 = 60_000,
    backlog: u31 = 128,
};

pub const Event = union(enum) { accept: void, read: *Client, write: *Client, err: void, closed: void };

pub fn Listener(comptime PollType: type) type {
    return struct {
        allocator: Allocator,
        config: Config,
        connected: usize,
        listener: posix.socket_t = undefined,
        client_pool: std.heap.MemoryPool(Client),
        read_timeout_list: ClientList,
        client_node_pool: std.heap.MemoryPool(ClientNode),
        pending_free_list: []*Client,
        pending_count: usize = 0,
        poll: PollType,
        id: usize,

        const Self = @This();

        pub fn init(allocator: Allocator, config: Config, id: usize) !Self {
            const poll = try PollType.init();
            const client_free_list = try allocator.alloc(*Client, config.max_clients);

            return .{
                .id = id,
                .poll = poll,
                .config = config,
                .connected = 0,
                .allocator = allocator,
                .client_pool = std.heap.MemoryPool(Client).init(allocator),
                .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator),
                .read_timeout_list = .{},
                .pending_free_list = client_free_list,
            };
        }

        pub fn deinit(self: *Self) void {
            self.poll.deinit();
            self.client_pool.deinit();
            self.client_node_pool.deinit();
            self.allocator.free(self.pending_free_list);
        }

        pub fn run(self: *Self, address: std.net.Address) !void {
            const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
            const protocol = posix.IPPROTO.TCP;

            self.listener = try posix.socket(address.any.family, tpe, protocol);
            defer posix.close(self.listener);

            try posix.setsockopt(self.listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

            if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
                try posix.setsockopt(self.listener, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
            } else if (@hasDecl(posix.SO, "REUSEPORT")) {
                try posix.setsockopt(self.listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }

            try posix.bind(self.listener, &address.any, address.getOsSockLen());
            try posix.listen(self.listener, self.config.backlog);

            try self.poll.addListener(self.listener);

            while (true) {
                const next_timeout = self.enforceTimeout();
                var it = try self.poll.wait(next_timeout);

                while (it.next()) |ready| {
                    std.debug.print("Listener {d}\n", .{self.id});
                    switch (ready) {
                        .accept => self.accept(self.listener) catch |err| log.err("failed to accept: {}", .{err}),
                        .read => |client| {
                            const msg = client.readMessage() catch |err| {
                                std.debug.print("read error: {any}\n", .{err});
                                self.removeClient(client);
                                continue;
                            } orelse continue;

                            std.debug.print("got: {s}\n", .{msg});

                            client.read_timeout = std.time.milliTimestamp() + self.config.read_timeout_ms;
                            self.read_timeout_list.remove(&(client.read_timeout_node.node));
                            self.read_timeout_list.append(&(client.read_timeout_node.node));

                            client.writeMessage(msg, &self.poll) catch |err| {
                                std.debug.print("write error: {any}\n", .{err});
                                self.removeClient(client);
                                continue;
                            };

                            if (client.to_write.len > 0) continue;
                        },
                        .write => |client| {
                            client.write(&self.poll) catch self.removeClient(client);
                        },
                        .err, .closed => continue,
                    }
                }

                if (self.pending_count > 0) self.drainPendingClient();
            }
        }

        fn drainPendingClient(self: *Self) void {
            for (self.pending_free_list[0..self.pending_count]) |c| {
                c.deinit(self.allocator);
                self.client_node_pool.destroy(c.read_timeout_node);
                self.client_pool.destroy(c);
            }

            self.pending_count = 0;
        }

        fn accept(self: *Self, listener: posix.socket_t) !void {
            const available = self.config.max_clients - self.connected;
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
                ) catch |err| {
                    log.err("failed to initialize client: {}", .{err});
                    posix.close(socket);
                    self.client_pool.destroy(client);
                    return;
                };

                client.read_timeout = std.time.milliTimestamp() + self.config.read_timeout_ms;
                client.read_timeout_node = try self.client_node_pool.create();
                errdefer self.client_node_pool.destroy(client.read_timeout_node);

                client.read_timeout_node.data = client;
                self.read_timeout_list.append(&(client.read_timeout_node.node));
                errdefer self.read_timeout_list.remove(&(client.read_timeout_node.node));

                try self.poll.newClient(client);

                std.debug.print("New Client Connected: {f}\n", .{client.address});

                self.connected += 1;
            }
        }

        fn enforceTimeout(self: *Self) i32 {
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

        fn removeClient(self: *Self, client: *Client) void {
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
}
