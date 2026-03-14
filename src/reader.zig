const std = @import("std");
const posix = std.posix;

pub const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Reader {
        return .{ .buf = try allocator.alloc(u8, size), .start = 0, .pos = 0 };
    }

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    // readMessage -> bufferredReader() -> ensureSpace()
    pub fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
        while (true) { // process every buffered messages 
            if (try self.bufferedReader()) |msg| return msg;
            const n = try posix.read(socket, self.buf[self.pos..]);
            if (n == 0) return error.Closed;
            self.pos += n;
            std.debug.print("Recieved: {X}\n", .{self.buf[self.start..self.pos]});
            std.debug.print("Buffer Len: {any}\n", .{self.pos});
        }
    }

    fn bufferedReader(self: *Reader) !?[]u8 {
        std.debug.assert(self.pos >= self.start);

        const unprocessed = self.buf[self.start..self.pos];
        if (unprocessed.len < 4) {
            try self.ensureSpace(4);
            return null;
        }

        const messagelen = std.mem.readInt(u32, unprocessed[0..4], .little);
        const totallen = messagelen + 4;
        std.debug.print("total len: {d}\n", .{totallen});

        if (unprocessed.len < totallen) {
            try self.ensureSpace(totallen);
            return null;
        }

        self.start += totallen;
        return unprocessed[4..totallen];
    }

    fn ensureSpace(self: *Reader, space: usize) !void {
        if (self.buf.len < space) return error.BufferTooSmall;
        if (self.buf.len - self.start >= space) return;

        const unprocessed = self.buf[self.start..self.pos];
        @memmove(self.buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};
