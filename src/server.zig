const std = @import("std");
const Client = @import("client.zig").Client;
const ClientNode = Client.ClientNode;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tcp_demo);

const READ_TIMEOUT = 60_000;
pub const ClientList = std.DoublyLinkedList;

pub const Server = struct {
    allocator: Allocator,
    connected: usize,
    polls: []posix.pollfd,
    clients: []*Client,
    client_polls: []posix.pollfd,
    client_pool: std.heap.MemoryPool(Client),
    read_timeout_list: ClientList,
    client_node_pool: std.heap.MemoryPool(ClientNode),

    pub fn init(allocator: Allocator, max: usize) !Server {
        const polls = try allocator.alloc(posix.pollfd, max + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(*Client, max);
        errdefer allocator.free(clients);

        return .{ .polls = polls, .connected = 0, .client_polls = polls[1..], .clients = clients, .allocator = allocator, .client_pool = std.heap.MemoryPool(Client).init(allocator), .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator), .read_timeout_list = .{} };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
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

        self.polls[0] = posix.pollfd{ .fd = listener, .revents = 0, .events = posix.POLL.IN };

        while (true) {
            const next_timeout = self.enforceTimeout();
            _ = try posix.poll(self.polls[0 .. self.connected + 1], next_timeout);

            if (self.polls[0].revents != 0) {
                self.accept(listener) catch |err| log.err("failed to accept: {}", .{err});
            }

            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    i += 1;
                    continue;
                }

                var client = self.clients[i];
                if (revents & posix.POLL.IN == posix.POLL.IN) {
                    while (true) {
                        const msg = client.readMessage() catch {
                            self.removeClient(i);
                            break;
                        } orelse {
                            i += 1;
                            break;
                        };

                        client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT;
                        self.read_timeout_list.remove(&client.read_timeout_node.node);
                        self.read_timeout_list.append(&client.read_timeout_node.node);

                        const written = client.writeMessage(msg) catch {
                            self.removeClient(i);
                            break;
                        };

                        if (written == false) {
                            self.client_polls[i].events = posix.POLL.OUT;
                            break;
                        }

                        std.debug.print("got: {s}\n", .{msg});
                    }
                } else if (revents & posix.POLL.OUT == posix.POLL.OUT) {
                    const written = client.write() catch {
                        self.removeClient(i);
                        continue;
                    };

                    if (written) {
                        self.client_polls[i].events = posix.POLL.IN;
                    }
                }
            }
        }
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        const available = self.client_polls.len - self.connected;
        for (0..available) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client: *Client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);

            client.* = Client.init(self.allocator, socket, address) catch |err| {
                posix.close(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };

            client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT;
            client.read_timeout_node = try self.client_node_pool.create();
            errdefer self.client_node_pool.destroy(client.read_timeout_node);

            client.read_timeout_node.data = client;
            self.read_timeout_list.append(&client.read_timeout_node.node);

            self.clients[self.connected] = client;
            self.client_polls[self.connected] = .{
                .fd = socket,
                .revents = 0,
                .events = posix.POLL.IN,
            };
            self.connected += 1;
        } else {
            self.polls[0].events = 0;
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

    fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];
        defer {
            posix.close(client.socket);
            self.client_node_pool.destroy(client.read_timeout_node);
            client.deinit(self.allocator);
            self.client_pool.destroy(client);
        }

        const last_index = self.connected - 1;
        self.clients[at] = self.clients[last_index];
        self.client_polls[at] = self.client_polls[last_index];
        self.connected = last_index;
        self.polls[0].events = posix.POLL.IN;
        self.read_timeout_list.remove(&client.read_timeout_node.node);
    }
};
