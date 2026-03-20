const std = @import("std");
const Client = @import("client.zig").Client;
const Epoll = @import("epoll.zig").Epoll;
const ClientNode = Client.ClientNode;
const net = std.net;
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tcp_demo);

const READ_TIMEOUT = 60_000;
pub const ClientList = std.DoublyLinkedList;

pub const Server = struct {
    allocator: Allocator,
    connected: usize,
    max: usize,
    client_pool: std.heap.MemoryPool(Client),
    read_timeout_list: ClientList,
    client_node_pool: std.heap.MemoryPool(ClientNode),
    poll: Epoll,

    pub fn init(allocator: Allocator, max: usize) !Server {
        const poll = try Epoll.init();
        return .{ .poll = poll, .max = max, .connected = 0, .allocator = allocator, .client_pool = std.heap.MemoryPool(Client).init(allocator), .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator), .read_timeout_list = .{} };
    }

    pub fn deinit(self: *Server) void {
        self.poll.deinit();
        self.client_pool.deinit();
        self.client_node_pool.deinit();
    }

    pub fn run(self: *Server, address: std.net.Address) !void {
        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;

        const listener = try posix.socket(address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        try self.poll.addListener(listener);

        while (true) {
            const next_timeout = self.enforceTimeout();
            const ready_events = self.poll.wait(next_timeout);

            for (ready_events) |ready| {
                switch (ready.data.ptr) {
                    0 => self.accept(listener) catch |err| log.err("failed to accept: {}", .{err}),
                    else => |nptr| {
                        const events = ready.events;
                        const client: *Client = @ptrFromInt(nptr);

                        if (events & linux.EPOLL.IN == linux.EPOLL.IN) {
                            while (true) {
                                const msg = client.readMessage() catch {
                                    self.removeClient(client);
                                    break;
                                } orelse break;

                                client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT;
                                self.read_timeout_list.remove(&client.read_timeout_node.node);
                                self.read_timeout_list.append(&client.read_timeout_node.node);

                                client.writeMessage(msg) catch {
                                    self.removeClient(client);
                                    break;
                                };
                                
                                if (client.to_write.len > 0) break;
                                std.debug.print("got: {s}\n", .{msg});
                            }
                        } else if (events & linux.EPOLL.OUT == linux.EPOLL.OUT) {
                            client.write() catch self.removeClient(client);
                        }
                    },
                }
            }
        }
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        const available = self.max - self.connected;
        if (available <= 0) {
            std.debug.print("No space for available for client. Paused Accepting", .{});
            return;
        }

        for (0..available) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client: *Client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);

            client.* = Client.init(self.allocator, socket, address, &self.poll) catch |err| {
                log.err("failed to initialize client: {}", .{err});
                posix.close(socket);
                self.client_pool.destroy(client);
                return;
            };

            client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT;
            client.read_timeout_node = try self.client_node_pool.create();
            errdefer self.client_node_pool.destroy(client.read_timeout_node);

            client.read_timeout_node.data = client;
            self.read_timeout_list.append(&client.read_timeout_node.node);
            errdefer self.read_timeout_list.remove(&client.read_timeout_node.node);

            try self.poll.newClient(client);
            self.connected += 1;
        }
    }

    fn enforceTimeout(self: *Server) i32 {
        const now = std.time.milliTimestamp();
        var node = self.read_timeout_list.first;

        while (node) |n| : (node = n.next) {
            const l: *ClientNode = @fieldParentPtr("node", n);
            const client = l.data;
            const diff = client.read_timeout - now;
            if (diff > 0) {
                return @intCast(diff);
            }

            posix.shutdown(client.socket, .recv) catch {};
        } else {
            return -1;
        }
    }

    fn removeClient(self: *Server, client: *Client) void {
        self.read_timeout_list.remove(&client.read_timeout_node.node);
        posix.close(client.socket);
        self.client_node_pool.destroy(client.read_timeout_node);
        client.deinit(self.allocator);
        self.client_pool.destroy(client);
        self.connected -= 1;
    }
};
