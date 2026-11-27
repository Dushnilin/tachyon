#!/usr/bin/env python3
"""Ephemeral local HTTPS and SOCKS5 fixtures for service-probe integration tests."""

import http.server
import json
import os
import select
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time
from pathlib import Path


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/redirect-http":
            self.send_response(302)
            self.send_header(
                "Location",
                f"http://localhost:{self.server.plain_port}/ok",
            )
            self.end_headers()
            return

        if path == "/forbidden":
            status, body = 403, b"forbidden"
        elif path == "/rate-limit":
            status, body = 429, b"rate limited"
        elif path == "/truncated":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.end_headers()
            try:
                self.wfile.write(b"short")
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            finally:
                self.connection.close()
            return
        else:
            status, body = 200, b"ok"

        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def log_message(self, *_args):
        return


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def recv_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


class SocksHandler(socketserver.BaseRequestHandler):
    def handle(self):
        upstream = None
        client = self.request
        try:
            greeting = recv_exact(client, 2)
            if not greeting or greeting[0] != 5:
                return
            methods = recv_exact(client, greeting[1])
            if methods is None or 0 not in methods:
                client.sendall(b"\x05\xff")
                return
            client.sendall(b"\x05\x00")

            request = recv_exact(client, 4)
            if not request or request[0] != 5 or request[1] != 1:
                return
            atyp = request[3]
            if atyp == 1:
                host = socket.inet_ntoa(recv_exact(client, 4))
            elif atyp == 3:
                length = recv_exact(client, 1)[0]
                host = recv_exact(client, length).decode("idna")
            elif atyp == 4:
                host = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16))
            else:
                return
            port = int.from_bytes(recv_exact(client, 2), "big")
            upstream = socket.create_connection((host, port), timeout=5)
            with open(self.server.hits_file, "ab") as hits:
                hits.write(b"x")
            client.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")

            client.setblocking(False)
            upstream.setblocking(False)
            while True:
                readable, _, exceptional = select.select(
                    [client, upstream], [], [client, upstream], 10
                )
                if exceptional:
                    return
                if not readable:
                    continue
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    target = upstream if source is client else client
                    target.sendall(data)
        except (OSError, IndexError, TypeError):
            try:
                client.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            except OSError:
                pass
        finally:
            if upstream is not None:
                upstream.close()


class ThreadingSocksServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    directory = Path(tempfile.mkdtemp(prefix="tachyon-service-probe-"))
    key_path = directory / "key.pem"
    cert_path = directory / "cert.pem"
    hits_path = directory / "socks-hits"
    hits_path.write_bytes(b"")

    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key_path), "-out", str(cert_path), "-days", "1",
            "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    plain = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    tls = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    tls.plain_port = plain.server_port
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert_path), str(key_path))
    tls.socket = context.wrap_socket(tls.socket, server_side=True)

    socks = ThreadingSocksServer(("127.0.0.1", 0), SocksHandler)
    socks.hits_file = str(hits_path)

    for server in (plain, tls, socks):
        threading.Thread(target=server.serve_forever, daemon=True).start()

    print(
        json.dumps(
            {
                "tls_port": tls.server_port,
                "plain_port": plain.server_port,
                "socks_port": socks.server_address[1],
                "cert_path": str(cert_path),
                "hits_path": str(hits_path),
            }
        ),
        flush=True,
    )
    try:
        while True:
            time.sleep(3600)
    finally:
        for server in (plain, tls, socks):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
