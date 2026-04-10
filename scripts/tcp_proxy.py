#!/usr/bin/env python3
"""Minimal TCP proxy that logs raw bytes in both directions."""
import socket
import sys
import threading

def forward(src, dst, label, log_file):
    """Forward data from src to dst, logging each chunk."""
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            with open(log_file, 'ab') as f:
                f.write(f"\n=== {label} ({len(data)} bytes) ===\n".encode())
                # Write hex dump
                for i in range(0, len(data), 16):
                    chunk = data[i:i+16]
                    hex_part = ' '.join(f'{b:02x}' for b in chunk)
                    ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
                    f.write(f"  {i:04x}: {hex_part:<48s}  {ascii_part}\n".encode())
                # Also write raw text for readability
                f.write(b"--- raw text ---\n")
                f.write(data)
                f.write(b"\n--- end ---\n")
            dst.sendall(data)
    except Exception as e:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass

def main():
    listen_port = int(sys.argv[1])
    target_host = sys.argv[2]
    target_port = int(sys.argv[3])
    log_file = sys.argv[4] if len(sys.argv) > 4 else '/tmp/proxy.log'

    # Clear log
    open(log_file, 'w').close()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', listen_port))
    server.listen(5)
    print(f"Proxy listening on 127.0.0.1:{listen_port} -> {target_host}:{target_port}")
    print(f"Logging to {log_file}")

    while True:
        client, addr = server.accept()
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream.connect((target_host, target_port))

        t1 = threading.Thread(target=forward, args=(client, upstream, "CLIENT->SERVER", log_file), daemon=True)
        t2 = threading.Thread(target=forward, args=(upstream, client, "SERVER->CLIENT", log_file), daemon=True)
        t1.start()
        t2.start()

if __name__ == '__main__':
    main()
