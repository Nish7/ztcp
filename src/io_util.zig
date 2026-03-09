/// Unused writer and read io message utilities
const std = @import("std");
const net = std.net;
const posix = std.posix;

fn writeMesssage(socket: posix.socket_t, msg: []const u8) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(msg.len), .little);
    try writeAll(socket, &buf);
    try writeAll(socket, msg);
}

fn writeAll(socket: posix.socket_t, msg: []const u8) !void {
    var pos: usize = 0;
    while (pos < msg.len) {
        const written = try posix.write(socket, msg[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}

fn readMessage(socket: posix.socket_t, buf: []u8) ![]u8 {
    var header: [4]u8 = undefined;
    try readAll(socket, &header);

    const len = std.mem.readInt(u32, &header, .little);
    if (len > buf.len) {
        return error.BufferTooSmall;
    }

    const msg = buf[0..len];
    try readAll(socket, msg);
    return msg;
}

fn readAll(socket: posix.socket_t, buf: []u8) !void {
    var into = buf;
    while (into.len > 0) {
        const n = try .posix.read(socket, into);
        if (n == 0) {
            return error.Closed;
        }

        into = into[n..];
    }
}

fn write(socket: posix.socket_t, msg: []const u8) !void {
    var pos: usize = 0;
    while (pos < msg.len) {
        const written = try posix.write(socket, msg[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}

// vectoriesed
fn writeMesssageVec(socket: posix.socket_t, msg: []const u8) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(msg.len), .little);

    var vec = [2]posix.iovec_const{
        .{ .len = 4, .base = &buf },
        .{ .len = msg.len, .base = msg.len },
    };

    try writeAllVectored(socket, &vec);
}

fn writeAllVectored(socket: posix.socket_t, vec: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try posix.writev(socket, vec[i..]);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }

        vec[i].base += n;
        vec[i].len -= n;
    }
}
