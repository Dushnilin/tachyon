#!/usr/bin/env bash
# Exercise generated packet-classification rules in disposable network/mount
# namespaces. Socket delivery through TPROXY is outside this test's scope.
set -euo pipefail

if [ "${TACHYON_TS_TEST_NETNS:-}" != "1" ]; then
  for tool in unshare mount ip nft python3 nsenter ucode; do
    command -v "$tool" >/dev/null || { printf 'skipped: %s unavailable\n' "$tool"; exit 0; }
  done
  if [ "$(id -u)" != "0" ] || ! unshare --net --mount --propagation private true 2>/dev/null; then
    printf 'skipped: requires root with network/mount namespace support\n'
    exit 0
  fi
  for startup in early late; do
    unshare --net --mount --propagation private \
      env TACHYON_TS_TEST_NETNS=1 TACHYON_TS_STARTUP="$startup" bash "$0"
  done
  exit 0
fi

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# sysfs must reflect this network namespace for tailscale_bypass_active().
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /run
export TACHYON_LIB WORK_DIR

python3 - <<'PY'
import json
import os
import pathlib
import socket
import subprocess
import time

lib = pathlib.Path(os.environ['TACHYON_LIB'])
work = pathlib.Path(os.environ['WORK_DIR'])
apply_uc = os.environ.get('NFT_APPLY_UC', str(lib / 'nft/apply.uc'))
real_nft = subprocess.check_output(['which', 'nft'], text=True).strip()
startup = os.environ['TACHYON_TS_STARTUP']
fake4, fake6 = '198.18.0.1', 'fc00::1'
public4, public6 = '8.8.8.8', '2606:4700:4700::1111'


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{args}: {result.stderr}')
    return result.stdout


def nft(*args, **kwargs):
    return run(real_nft, *args, **kwargs)


def send(address, mark=0, protocol=socket.SOCK_DGRAM):
    with socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET,
                       protocol) as sock:
        if mark:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
        if protocol == socket.SOCK_STREAM:
            sock.setblocking(False)
            sock.connect_ex((address, 8443))
        else:
            sock.sendto(b'tailscale-fakeip-regression', (address, 8443))
    time.sleep(0.05)


def counters(chain):
    result = {}
    for item in json.loads(nft('-j', 'list', 'chain', 'inet', 'probe', chain))['nftables']:
        rule = item.get('rule', {})
        if 'comment' in rule:
            result[rule['comment']] = sum(e.get('counter', {}).get('packets', 0)
                                          for e in rule.get('expr', []))
    return result


def expect_packet(chain, key, action):
    before = counters(chain)[key]
    action()
    after = counters(chain)[key]
    assert after == before + 1, (startup, key, before, after)


run('ip', 'link', 'set', 'lo', 'up')
run('ip', 'link', 'add', 'wan0', 'type', 'dummy')
run('ip', 'link', 'set', 'wan0', 'up')
run('ip', 'addr', 'add', '192.0.2.1/24', 'dev', 'wan0')
run('ip', '-6', 'addr', 'add', '2001:db8:1::1/64', 'dev', 'wan0', 'nodad')
for family, default in [('-4', '0.0.0.0/0'), ('-6', '::/0')]:
    run('ip', family, 'route', 'add', 'default', 'dev', 'wan0')
    run('ip', family, 'route', 'add', 'local', default, 'dev', 'lo', 'table', '105')
    run('ip', family, 'rule', 'add', 'fwmark', '0x04000000/0x04000000',
        'lookup', '105', 'priority', '105')

if startup == 'early':
    run('ip', 'link', 'add', 'tailscale0', 'type', 'dummy')
    run('ip', 'link', 'set', 'tailscale0', 'up')

# Record the real generator's argv and transient nft batch files first.
stub = work / 'nft'
stub.write_text('''#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
entry = {'args': args}
if '-f' in args:
    entry['input'] = open(args[args.index('-f') + 1]).read()
with open(os.environ['NFT_LOG'], 'a') as output:
    output.write(json.dumps(entry) + '\\n')
''')
stub.chmod(0o755)
log = work / 'nft.jsonl'
state = work / 'uci.state'
state.write_text('tachyon.settings=settings\n')
env = {**os.environ, 'PATH': str(work) + ':' + os.environ['PATH'],
       'NFT_LOG': str(log), 'TACHYON_UCI_STATE_FILE': str(state)}
base = ['ucode', '-L', str(lib), apply_uc]
run(*base, 'nft-create-runtime-base', 'TachyonTest', 'localv4', 'common4',
    'ports', 'ipports4', 'interfaces', 'br-lan', '0x04000000', '0x08000000',
    '198.18.0.0/15', '1602', '0', 'localv6', 'common6', 'ipports6',
    'fc00::/18', '::1', '0', 'off', env=env)
run(*base, 'nft-create-runtime-output-rules', 'TachyonTest', 'localv4',
    'common4', 'ports', 'ipports4', '0x04000000', '198.18.0.0/15',
    'localv6', 'common6', 'ipports6', 'fc00::/18', env=env)
for line in log.read_text().splitlines():
    entry = json.loads(line)
    args = entry['args']
    # Observe marks before socket delivery. Some test kernels lack these modules.
    if 'fib' in args or 'tproxy' in args:
        continue
    if 'input' in entry:
        nft('-f', '-', input=entry['input'])
    else:
        nft(*args)

if startup == 'late':
    run('ip', 'link', 'add', 'tailscale0', 'type', 'dummy')
    run('ip', 'link', 'set', 'tailscale0', 'up')
run('ip', '-6', 'addr', 'add', 'fd7a:115c:a1e0::1/64', 'dev', 'tailscale0', 'nodad')
nft('-f', '-', input='''table inet probe {
 chain output { type filter hook output priority -140; policy accept; }
 chain prerouting { type filter hook prerouting priority -148; policy accept; }
}''')
for index, (family, address, public) in enumerate([('ip', fake4, public4), ('ip6', fake6, public6)]):
    nft('add', 'element', 'inet', 'TachyonTest', f'common{4 if index == 0 else 6}', '{ ' + public + ' }')
    for mark, name, destination in [('0x04000000', 'fake', address),
                                    ('0x00080000', 'daemon', public),
                                    ('0x08000000', 'core', public)]:
        nft('add', 'rule', 'inet', 'probe', 'output', family, 'daddr', destination,
            'meta', 'mark', mark, 'counter', 'comment', name + str(index))
    expect_packet('output', 'fake' + str(index), lambda a=address: send(a))

for family in ['-4', '-6']:
    run('ip', family, 'route', 'add', 'default', 'dev', 'tailscale0', 'table', '52')
    run('ip', family, 'rule', 'add', 'lookup', '52', 'priority', '5270')
    run('ip', family, 'rule', 'add', 'fwmark', '0x80000/0xff0000',
        'lookup', 'main', 'priority', '5210')
for index, (address, public) in enumerate([(fake4, public4), (fake6, public6)]):
    # FakeIP survives exit-node routing and both tunnel/daemon bypass marks.
    for protocol in [socket.SOCK_DGRAM, socket.SOCK_STREAM]:
        for mark in [0, 0x200000, 0x80000]:
            expect_packet('output', 'fake' + str(index), lambda a=address, m=mark, p=protocol: send(a, m, p))
        expect_packet('output', 'daemon' + str(index), lambda a=public, p=protocol: send(a, 0x80000, p))
        expect_packet('output', 'core' + str(index), lambda a=public, p=protocol: send(a, 0x8000000, p))

# Deliver real packets from another namespace through a tailscale0 veth.
run('ip', 'link', 'del', 'tailscale0')
peer = subprocess.Popen(['unshare', '--net', 'sleep', '120'])
try:
    for _ in range(100):
        if os.readlink(f'/proc/{peer.pid}/ns/net') != os.readlink('/proc/self/ns/net'):
            break
        time.sleep(0.01)
    run('ip', 'link', 'add', 'tailscale0', 'type', 'veth', 'peer', 'name', 'peer0')
    run('ip', 'link', 'set', 'peer0', 'netns', str(peer.pid))
    run('ip', 'link', 'set', 'tailscale0', 'up')
    run('ip', 'addr', 'add', '100.74.0.1/24', 'dev', 'tailscale0')
    run('ip', '-6', 'addr', 'add', 'fd7a:115c:a1e0::1/64', 'dev', 'tailscale0', 'nodad')
    prefix = ['nsenter', '-t', str(peer.pid), '-n']
    run(*prefix, 'ip', 'link', 'set', 'lo', 'up')
    run(*prefix, 'ip', 'link', 'set', 'peer0', 'up')
    run(*prefix, 'ip', 'addr', 'add', '100.74.0.2/24', 'dev', 'peer0')
    run(*prefix, 'ip', '-6', 'addr', 'add', 'fd7a:115c:a1e0::2/64', 'dev', 'peer0', 'nodad')
    run(*prefix, 'ip', 'route', 'add', 'default', 'via', '100.74.0.1')
    run(*prefix, 'ip', '-6', 'route', 'add', 'default', 'via', 'fd7a:115c:a1e0::1')
    for interface in ['tailscale0', 'br-lan', 'wan-in']:
        if interface != 'tailscale0':
            run('ip', 'link', 'set', 'tailscale0' if interface == 'br-lan' else 'br-lan', 'name', interface)
        for index, (family, address, public) in enumerate([('ip', fake4, public4), ('ip6', fake6, public6)]):
            for destination, mark, label in [(address, '0' if interface == 'wan-in' else '0x04000000', 'fake'),
                                              (public, '0x04000000' if interface == 'br-lan' else '0', 'real')]:
                key = f'{interface}_{label}{index}'
                nft('add', 'rule', 'inet', 'probe', 'prerouting', 'iifname', interface,
                    family, 'daddr', destination, 'meta', 'mark', mark, 'counter', 'comment', key)
                for protocol in [socket.SOCK_DGRAM, socket.SOCK_STREAM]:
                    operation = (f's.setblocking(False);s.connect_ex(({destination!r},8443))'
                                 if protocol == socket.SOCK_STREAM else
                                 f's.sendto(b"test",({destination!r},8443))')
                    code = ('import socket,time;'
                            f's=socket.socket({socket.AF_INET6 if index else socket.AF_INET},{protocol});'
                            f'{operation};time.sleep(.1);s.close()')
                    expect_packet('prerouting', key, lambda c=code: run(*prefix, 'python3', '-c', c))
finally:
    peer.terminate()
    peer.wait()

print(f'PASS: Tailscale {startup} startup; IPv4/IPv6 TCP/UDP FakeIP, transport bypass, LAN/WAN classification')
PY
