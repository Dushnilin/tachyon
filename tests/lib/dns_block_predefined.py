import json
import os
import pathlib
import socket
import struct
import subprocess
import sys
import threading
import time


def dns_name(packet, offset):
    labels = []
    end = None
    for _ in range(128):
        size = packet[offset]
        if size & 0xC0 == 0xC0:
            if end is None:
                end = offset + 2
            offset = ((size & 0x3F) << 8) | packet[offset + 1]
        elif size == 0:
            return '.'.join(labels) + '.', end or offset + 1
        else:
            labels.append(packet[offset + 1:offset + 1 + size].decode('ascii'))
            offset += size + 1
    raise AssertionError('DNS name compression loop')


def question(host, qtype):
    name = b''.join(bytes([len(label)]) + label.encode() for label in host.split('.')) + b'\0'
    return struct.pack('!6H', 329, 0x100, 1, 0, 0, 0) + name + struct.pack('!HH', qtype, 1)


def response_answer(packet, host, qtype, expected):
    ident, flags, questions, answers, _, _ = struct.unpack_from('!6H', packet)
    assert ident == 329 and flags & 0x8000 and flags & 15 == 0, (host, 'not NOERROR')
    assert questions == 1 and answers == 1, (host, 'expected one answer')
    _, offset = dns_name(packet, 12)
    owner, offset = dns_name(packet, offset + 4)
    rr_type, rr_class, ttl, size = struct.unpack_from('!HHIH', packet, offset)
    assert owner.lower() == host.lower() + '.', (host, owner)
    assert rr_type == qtype and rr_class == 1 and ttl == 60, (host, rr_type, ttl)
    address = socket.inet_ntop(socket.AF_INET if qtype == 1 else socket.AF_INET6, packet[offset + 10:offset + 10 + size])
    assert address == expected, (host, address, expected)


def live_check(binary, rules, work):
    queries = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as upstream:
        upstream.bind(('127.0.0.1', 0))
        upstream.settimeout(0.1)
        stopped = threading.Event()

        def serve():
            while not stopped.is_set():
                try:
                    packet, peer = upstream.recvfrom(4096)
                except socket.timeout:
                    continue
                name, offset = dns_name(packet, 12)
                qtype, _ = struct.unpack_from('!HH', packet, offset)
                queries.append(name)
                address = '203.0.113.42' if qtype == 1 else '2001:db8::42'
                raw = socket.inet_pton(socket.AF_INET if qtype == 1 else socket.AF_INET6, address)
                header = struct.pack('!6H', struct.unpack_from('!H', packet)[0], 0x8180, 1, 1, 0, 0)
                answer = b'\xc0\x0c' + struct.pack('!HHIH', qtype, 1, 60, len(raw)) + raw
                upstream.sendto(header + packet[12:offset + 4] + answer, peer)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        config = {
            'log': {'disabled': True},
            'dns': {
                'servers': [{'type': 'udp', 'tag': 'upstream', 'server': '127.0.0.1', 'server_port': upstream.getsockname()[1]}],
                'rules': rules,
                'final': 'upstream',
            },
            'inbounds': [{'type': 'direct', 'tag': 'source-dns-in', 'listen': '127.0.0.1', 'listen_port': port}],
            'outbounds': [{'type': 'direct', 'tag': 'direct'}],
            'route': {'rules': [{'inbound': ['source-dns-in'], 'action': 'hijack-dns'}], 'final': 'direct'},
        }
        config_file = work / 'live.json'
        config_file.write_text(json.dumps(config))
        subprocess.run([binary, 'check', '-c', str(config_file)], check=True)
        try:
            with (work / 'core.log').open('w+') as log:
                process = subprocess.Popen([binary, 'run', '-c', str(config_file)], stdout=log, stderr=log)
                try:
                    for host in ['blocked.example', 'sub.blocked.example', 'MiXeD.blocked.example', 'allowed.example']:
                        for qtype in [1, 28]:
                            for attempt in range(30):
                                assert process.poll() is None, 'DNS core exited early'
                                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                                    client.settimeout(0.1)
                                    client.sendto(question(host, qtype), ('127.0.0.1', port))
                                    try:
                                        packet = client.recv(4096)
                                        break
                                    except socket.timeout:
                                        if attempt == 29:
                                            raise
                                        time.sleep(0.02)
                            expected = ('203.0.113.42' if qtype == 1 else '2001:db8::42') if host == 'allowed.example' else ('0.0.0.0' if qtype == 1 else '::')
                            response_answer(packet, host, qtype, expected)
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
        finally:
            stopped.set()
            thread.join(timeout=2)
        assert queries and all(name == 'allowed.example.' for name in queries), queries
    print('PASS: real sing-box DNS A/AAAA, queried owner names, subdomains and unblocked upstream traffic')


def main():
    lib = pathlib.Path(sys.argv[1]).resolve()
    work = pathlib.Path(sys.argv[2]).resolve()
    fixture = {
        'settings': {'.name': 'settings', '.type': 'settings', 'dns_server': ['77.88.8.8'], 'bootstrap_dns_server': ['77.88.8.8']},
        'section': [{'.name': 'block', '.type': 'section', 'enabled': '1', 'action': 'block', 'domain_suffix': ['blocked.example'], 'source_ip_cidr': ['127.0.0.1']}],
    }
    fixture_file = work / 'fixture.json'
    fixture_file.write_text(json.dumps(fixture))
    binary = os.environ.get('TACHYON_TEST_SING_BOX_BIN')
    binary_version = subprocess.check_output([binary, 'version'], text=True).splitlines()[0].split()[-1].lstrip('v') if binary else None
    live_checked = False
    for profile, version in [('extended', '1.14.3-extended-2.7.3'), ('stable', '1.12.0'), ('stable', '1.14.3'), ('lx', '1.14.2-lx.8'), ('tachyon-core', '0.3.4')]:
        (work / 'variant').write_text(profile)
        (work / 'version').write_text(version)
        env = dict(os.environ, TACHYON_LIB=str(lib), SB_VARIANT_STATE_FILE=str(work / 'variant'), SB_VERSION_STATE_FILE=str(work / 'version'), TACHYON_DNS_FAILOVER_STATE_FILE=str(work / 'no-dns-state'), TACHYON_SECTION_FAIL_STATE_FILE=str(work / 'no-fail-state'))
        output = work / f'{profile}-{version}.json'
        subprocess.run(['ucode', '-L', str(lib), str(lib / 'tachyon_core/generator.uc'), 'generate-config-fixture', str(fixture_file), str(output), '127.0.0.1', '0'], env=env, check=True)
        config = json.loads(output.read_text())
        rules = [rule for rule in config['dns']['rules'] if rule.get('action') == 'predefined' and rule.get('answer')]
        assert len(rules) == 2, (profile, rules)
        for qtype, ip in [('A', '0.0.0.0'), ('AAAA', '::')]:
            rule, = [rule for rule in rules if rule['query_type'] == [qtype]]
            assert rule['rcode'] == 'NOERROR' and '127.0.0.1/32' in rule['source_ip_cidr']
            answer, = rule['answer']
            if profile == 'tachyon-core':
                assert answer == {'ttl': 60, 'value': ip}, answer
            else:
                assert answer == f'*. 60 IN {qtype} {ip}', (profile, answer)
        print(f'PASS: DNS block records for {profile} {version}')
        if binary and version == binary_version:
            subprocess.run([binary, 'check', '-c', str(output)], check=True)
            live_check(binary, rules, work)
            live_checked = True
    assert not binary or live_checked, f'No fixture profile for sing-box {binary_version}'


if __name__ == '__main__':
    main()
