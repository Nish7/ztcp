#!/usr/bin/env python3
import argparse
import socket
import struct
import sys
import time


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RuntimeError("connection closed while reading response")
        buf.extend(chunk)
    return bytes(buf)


def recv_frame(sock: socket.socket) -> bytes:
    header = recv_exact(sock, 4)
    (size,) = struct.unpack("<I", header)
    return recv_exact(sock, size)


def send_frame(sock: socket.socket, message: bytes) -> None:
    sock.sendall(struct.pack("<I", len(message)) + message)


def main() -> int:
    parser = argparse.ArgumentParser(description="Send length-prefixed frames over one TCP connection.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5882)
    parser.add_argument("--delay", type=float, default=1.0, help="Delay in seconds between messages.")
    parser.add_argument(
        "messages",
        nargs="*",
        default=["hello", "world"],
        help="Messages to send on the same connection.",
    )
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port)) as sock:
        for i, message in enumerate(args.messages):
            data = message.encode("utf-8")
            print(f"send[{i}]: {message}")
            send_frame(sock, data)
            reply = recv_frame(sock)
            print(f"recv[{i}]: {reply!r}")
            if i + 1 != len(args.messages):
                time.sleep(args.delay)

    return 0


if __name__ == "__main__":
    sys.exit(main())
