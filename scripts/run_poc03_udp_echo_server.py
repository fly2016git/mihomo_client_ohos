#!/usr/bin/env python3
import argparse
import socket


def main() -> None:
    parser = argparse.ArgumentParser(description="POC-03 UDP echo server for local protect validation.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=53535)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.port))
    print(f"udp echo listening {args.host}:{args.port}", flush=True)

    while True:
        data, addr = sock.recvfrom(2048)
        print(f"echo {len(data)} bytes from {addr[0]}:{addr[1]}", flush=True)
        sock.sendto(data, addr)


if __name__ == "__main__":
    main()
