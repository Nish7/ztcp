#!/usr/bin/env python3
import argparse
import socket
import struct
import sys
import threading
import time


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5882


def recv_exact(sock: socket.socket, size: int) -> bytes:
    buf = bytearray()
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
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


def wait_for_port(host: str, port: int, timeout: float) -> None:
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.25):
                return
        except OSError as err:
            last_error = err
            time.sleep(0.05)
    raise RuntimeError(f"server did not start listening on {host}:{port}: {last_error}")


def run_client(
    host: str,
    port: int,
    messages: list[str],
    client_id: int,
    errors: list[str],
    lock: threading.Lock,
) -> None:
    try:
        with socket.create_connection((host, port), timeout=2.0) as sock:
            sock.settimeout(10.0)
            for index, message in enumerate(messages):
                payload = f"client={client_id};msg={index};body={message}".encode(
                    "utf-8"
                )
                send_frame(sock, payload)
                reply = recv_frame(sock)
                if reply != payload:
                    raise RuntimeError(
                        f"echo mismatch for client {client_id} message {index}: expected {payload!r}, got {reply!r}"
                    )
    except Exception as err:
        with lock:
            errors.append(str(err))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Regression test for the latest listener/event-loop diff against an already-running server."
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--clients", type=int, default=8, help="Concurrent client count."
    )
    parser.add_argument("--messages", type=int, default=4, help="Messages per client.")
    parser.add_argument("--startup-timeout", type=float, default=3.0)
    args = parser.parse_args()

    if args.clients <= 0 or args.messages <= 0:
        print("clients and messages must be positive", file=sys.stderr)
        return 2

    wait_for_port(args.host, args.port, args.startup_timeout)

    errors: list[str] = []
    lock = threading.Lock()
    clients = []

    for client_id in range(args.clients):
        messages = [f"hello-{client_id}-{index}" for index in range(args.messages)]
        thread = threading.Thread(
            target=run_client,
            args=(args.host, args.port, messages, client_id, errors, lock),
        )
        thread.start()
        clients.append(thread)

    for thread in clients:
        thread.join()

    if errors:
        print("regression test failed:", file=sys.stderr)
        for err in errors:
            print(f"- {err}", file=sys.stderr)
        return 1

    print(
        f"ok: {args.clients} concurrent clients x {args.messages} messages echoed correctly"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
