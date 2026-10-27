"""Optional real-engine regression, using only loopback DNS and TCP servers.

Run with: python3 dpi_routed_dns_runtime.py /path/to/sing-box generated.json
The config comes from dpi_routed_dns.sh; no binary is downloaded by this test.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(type=kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def read_exact(sock, size):
    data = b""
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise AssertionError("proxy closed the connection")
        data += part
    return data


def run(binary, generated, geoip_mode=None, country_match=True):
    stop = threading.Event()
    dns_socket = socket.socket(type=socket.SOCK_DGRAM)
    dns_socket.bind(("127.0.0.1", 0))
    dns_socket.settimeout(.1)
    tcp_socket = socket.socket()
    tcp_socket.bind(("127.0.0.1", 0))
    tcp_socket.listen()
    tcp_socket.settimeout(.1)
    upstream_port, target_port = dns_socket.getsockname()[1], tcp_socket.getsockname()[1]
    dns_port, proxy_port = free_port(socket.SOCK_DGRAM), free_port()

    def dns_server():
        while not stop.is_set():
            try:
                query, peer = dns_socket.recvfrom(4096)
                end = 12
                while query[end]:
                    end += 1 + query[end]
                query_type = struct.unpack("!H", query[end + 1:end + 3])[0]
                answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("127.0.0.1") if query_type == 1 else b""
                dns_socket.sendto(query[:2] + b"\x81\x80" + struct.pack("!HHHH", 1, bool(answer), 0, 0) + query[12:end + 5] + answer, peer)
            except socket.timeout:
                pass

    def tcp_server():
        while not stop.is_set():
            try:
                client, _ = tcp_socket.accept()
                with client:
                    client.sendall(b"LOCAL_DPI_TEST_OK")
            except socket.timeout:
                pass

    def remap(rule):
        result = dict(rule)
        if "rules" in result:
            result["rules"] = [remap(child) for child in result["rules"]]
        if "rule_set" in result:
            tags = result["rule_set"]
            tags = tags if isinstance(tags, list) else [tags]
            result["rule_set"] = ["geo" if "geoip" in tag else ("mixed" if "telegram" in tag else "domains") for tag in tags]
        if result.get("server") in ("dns-server", "dpi-routed-dns-server"):
            result["server"] = "real"
        return result

    def uses_ruleset(rule):
        return "rule_set" in rule or any(uses_ruleset(child) for child in rule.get("rules", []))

    threads = [threading.Thread(target=dns_server), threading.Thread(target=tcp_server)]
    process = None
    for thread in threads:
        thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="dpi-routed-dns-") as directory:
            root = Path(directory)
            for tag, rules in {
                "domains": [{"domain_suffix": ["domain-only.test"]}],
                "mixed": [{"domain_suffix": ["listed.example"]}, {"ip_cidr": ["127.0.0.1/32"]}],
                "geo": [{"ip_cidr": ["127.0.0.1/32" if country_match else "127.0.0.2/32"]}],
            }.items():
                (root / (tag + ".json")).write_text(json.dumps({"version": 3, "rules": rules}))
            config = {
                "log": {"level": "debug"},
                "dns": {
                    "servers": [{"type": "udp", "tag": "real", "server": "127.0.0.1", "server_port": upstream_port},
                                {"type": "fakeip", "tag": "fakeip-server", "inet4_range": "198.18.0.0/15"}],
                    "rules": [remap(rule) for rule in generated["dns"]["rules"] if rule.get("rule_set") or rule.get("action") == "evaluate"],
                    "final": "real",
                },
                "inbounds": [{"type": "direct", "tag": "dns-in", "listen": "127.0.0.1", "listen_port": dns_port, "network": "udp"},
                             {"type": "mixed", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": proxy_port}],
                "outbounds": [{"type": "direct", "tag": "direct-out"}, {"type": "direct", "tag": "dpi-out"}],
                "route": {
                    "rule_set": [{"type": "local", "tag": tag, "format": "source", "path": str(root / (tag + ".json"))} for tag in ("domains", "mixed", "geo")],
                    "rules": [{"inbound": "dns-in", "action": "hijack-dns"}] + [remap(rule) for rule in generated["route"]["rules"] if uses_ruleset(rule)],
                    "final": "direct-out", "default_domain_resolver": "real",
                },
            }
            (root / "config.json").write_text(json.dumps(config))
            with (root / "runtime.log").open("w+") as log:
                process = subprocess.Popen([binary, "run", "-c", str(root / "config.json")], stdout=log, stderr=log,
                                           creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            raise AssertionError("engine failed to start")
                        try:
                            with socket.create_connection(("127.0.0.1", proxy_port), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.05)
                    else:
                        raise AssertionError("engine did not become ready")
                    cases = [("ip-only.test", False), ("listed.example", False), ("domain-only.test", True)]
                    expected_outbound = "dpi-out"
                    if geoip_mode is not None:
                        cases = [("domain-only.test", False)]
                        use_dpi = country_match if geoip_mode == "include_all" else not country_match
                        expected_outbound = "dpi-out" if use_dpi else "direct-out"
                    for hostname, expected_fake in cases:
                        labels = b"".join(bytes([len(label)]) + label.encode() for label in hostname.split(".")) + b"\x00"
                        query = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + labels + struct.pack("!HH", 1, 1)
                        with socket.socket(type=socket.SOCK_DGRAM) as client:
                            client.settimeout(3)
                            client.sendto(query, ("127.0.0.1", dns_port))
                            response = client.recv(4096)
                        address = socket.inet_ntoa(response[-4:])
                        assert (ipaddress.ip_address(address) in ipaddress.ip_network("198.18.0.0/15")) == expected_fake, hostname + ": wrong DNS answer " + address
                        with socket.create_connection(("127.0.0.1", proxy_port), timeout=3) as client:
                            client.sendall(b"\x05\x01\x00")
                            assert read_exact(client, 2) == b"\x05\x00"
                            client.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(address) + struct.pack("!H", target_port))
                            reply = read_exact(client, 10)
                            assert reply[1] == 0 and read_exact(client, 17) == b"LOCAL_DPI_TEST_OK", hostname + ": loopback connection failed"
                    time.sleep(.1)
                finally:
                    process.terminate()
                    process.wait(timeout=5)
                log.seek(0)
                connections = [line for line in log.read().splitlines() if "outbound/direct[" in line and (":" + str(target_port)) in line]
                assert len(connections) == len(cases) and all("[" + expected_outbound + "]" in line for line in connections), "wrong outbound: " + repr(connections)
        if geoip_mode is None:
            print("Real-engine DNS and DPI routing passed: IP-only, mixed domain, domain-only")
        else:
            print("Real-engine GeoIP passed:", geoip_mode, "inside" if country_match else "outside", "->", expected_outbound)
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        stop.set()
        for thread in threads:
            thread.join(timeout=2)
        dns_socket.close()
        tcp_socket.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("config")
    parser.add_argument("--geoip-mode", choices=("exclude_direct", "include_all"))
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    generated = json.loads(Path(args.config).read_text(encoding="utf-8"))
    for country_match in (True, False) if args.geoip_mode else (True,):
        run(binary, generated, args.geoip_mode, country_match)
