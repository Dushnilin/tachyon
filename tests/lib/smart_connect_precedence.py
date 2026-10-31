"""Optional native-core routing regression. Every socket stays on loopback."""
import json
from pathlib import Path
import queue
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time


def exact(conn, size):
    data = b""
    while len(data) < size:
        part = conn.recv(size - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def address(conn, kind):
    size = {1: 4, 4: 16}.get(kind)
    if kind == 3:
        size = exact(conn, 1)[0]
    exact(conn, size)
    exact(conn, 2)


def run(binary, generated):
    config = json.loads(Path(generated).read_text())
    stop = threading.Event()
    seen = queue.Queue()
    sockets = []

    def proxy(tag):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(.2)
        sockets.append(listener)

        def worker():
            while not stop.is_set():
                try:
                    conn, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                try:
                    with conn:
                        conn.settimeout(2)
                        header = exact(conn, 2)
                        exact(conn, header[1])
                        conn.sendall(b"\x05\x00")
                        header = exact(conn, 4)
                        address(conn, header[3])
                        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                        seen.put(tag)
                        exact(conn, 1)
                except (OSError, EOFError):
                    pass

        threading.Thread(target=worker, daemon=True).start()
        return listener.getsockname()[1]

    dns = socket.socket(type=socket.SOCK_DGRAM)
    dns.bind(("127.0.0.1", 0))
    dns.settimeout(.2)
    sockets.append(dns)

    def answer_dns():
        while not stop.is_set():
            try:
                query, client = dns.recvfrom(4096)
                end = 12
                while query[end]:
                    end += query[end] + 1
                end += 1
                kind = struct.unpack("!H", query[end:end + 2])[0]
                response = bytearray(query[:end + 4])
                response[2:4] = b"\x81\x80"
                response[8:12] = b"\x00\x00\x00\x00"
                response[6:8] = b"\x00\x01" if kind == 1 else b"\x00\x00"
                if kind == 1:
                    response.extend(b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x01\x01\x01\x01")
                dns.sendto(response, client)
            except socket.timeout:
                continue
            except OSError:
                return

    threading.Thread(target=answer_dns, daemon=True).start()
    for outbound in config["outbounds"]:
        tag = outbound["tag"]
        outbound.clear()
        outbound.update(type="socks", tag=tag, server="127.0.0.1", server_port=proxy(tag), version="5")
    config["experimental"] = {}
    config["route"]["rule_set"] = []
    config["route"].pop("default_mark", None)
    config["route"]["auto_detect_interface"] = False
    config["dns"]["servers"] = [
        {"type": "udp", "tag": server["tag"], "server": "127.0.0.1", "server_port": dns.getsockname()[1]}
        for server in config["dns"]["servers"]
    ]
    config["dns"]["rules"] = []
    config["log"] = {"level": "error"}
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config["inbounds"] = [{"type": "socks", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": port}]
    process = None
    try:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps(config))
            with (Path(tmp) / "core.log").open("w+") as log:
                process = subprocess.Popen([binary, "run", "-c", str(path), "-D", tmp], stdout=log, stderr=subprocess.STDOUT)
                for _ in range(100):
                    try:
                        with socket.create_connection(("127.0.0.1", port), .1):
                            break
                    except OSError:
                        if process.poll() is not None:
                            log.seek(0)
                            raise AssertionError(log.read())
                        time.sleep(.05)
                else:
                    raise AssertionError("core did not listen")
                for kind, expected in [("http", "smart-connect-zapret-out"), ("tls", "proxy-out")]:
                    with socket.create_connection(("127.0.0.1", port), 3) as conn:
                        conn.settimeout(4)
                        conn.sendall(b"\x05\x01\x00")
                        assert exact(conn, 2) == b"\x05\x00"
                        host = b"zapret.example"
                        conn.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", 80 if kind == "http" else 443))
                        reply = exact(conn, 4)
                        assert reply[1] == 0, reply
                        address(conn, reply[3])
                        if kind == "http":
                            payload = b"HEAD / HTTP/1.1\r\nHost: zapret.example\r\n\r\n"
                        else:
                            incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
                            client = ssl.create_default_context().wrap_bio(incoming, outgoing, server_hostname="zapret.example")
                            try:
                                client.do_handshake()
                            except ssl.SSLWantReadError:
                                pass
                            payload = outgoing.read()
                        conn.sendall(payload)
                        actual = seen.get(timeout=5)
                        assert actual == expected, f"{kind}: expected {expected}, got {actual}"
                        print(f"PASS: native-core {kind} selects {actual}")
                process.terminate()
                process.wait(timeout=5)
                process = None
    finally:
        if process is not None:
            process.terminate()
            process.wait(timeout=5)
        stop.set()
        for item in sockets:
            item.close()


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2])
