#!/usr/bin/env bash
# End-to-end Keenetic / Entware emulation test harness inside Docker.
# Verifies real Linux binaries (tachyon + tachyon-core) with iptables, ipset,
# /opt/etc/init.d/S99tachyon, ndmc mock, FakeIP :1053, AdGuard/hosts -> .trs,
# and all diagnostic ubus RPC checks.
set -euo pipefail

export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="${TACHYON_CORE_DIR:-$(cd "$REPO_DIR/../tachyon-core" && pwd)}"

to_docker_mount() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p"
  else
    printf '%s\n' "$p"
  fi
}

TACHYON_MOUNT="$(to_docker_mount "$REPO_DIR")"
CORE_MOUNT="$(to_docker_mount "$CORE_DIR")"
SIM_IMAGE="${TACHYON_KEENETIC_SIM_IMAGE:-tachyon-keenetic-sim:latest}"
BUILD_IMAGE="${TACHYON_BUILD_IMAGE:-tachyon-core-test:latest}"

echo "==> [1/4] Building Linux x86_64 tachyon-core binary from $CORE_DIR..."
docker run --rm -i \
  -v "${CORE_MOUNT}:/work" \
  -v tachyon-core-linux-target:/target-linux \
  -v tachyon-core-cargo-registry:/usr/local/cargo/registry \
  -v tachyon-core-cargo-git:/usr/local/cargo/git \
  -e CARGO_TARGET_DIR=/target-linux \
  -w /work \
  "$BUILD_IMAGE" \
  cargo build --bin tachyon-core

echo "==> [2/4] Building Linux x86_64 tachyon binary from $REPO_DIR..."
docker run --rm -i \
  -v "${TACHYON_MOUNT}:/work" \
  -v tachyon-rs-linux-target:/target-tachyon \
  -v tachyon-core-cargo-registry:/usr/local/cargo/registry \
  -v tachyon-core-cargo-git:/usr/local/cargo/git \
  -e CARGO_TARGET_DIR=/target-tachyon \
  -w /work \
  "$BUILD_IMAGE" \
  cargo build --locked --bin tachyon

if ! docker image inspect "$SIM_IMAGE" >/dev/null 2>&1; then
  echo "==> [3/4] Creating runtime image $SIM_IMAGE..."
  docker build -t "$SIM_IMAGE" - <<'EOF'
FROM debian:bookworm-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 ipset iptables procps python3 \
 && rm -rf /var/lib/apt/lists/*
EOF
else
  echo "==> [3/4] Using cached runtime image $SIM_IMAGE..."
fi

echo "==> [4/4] Running Keenetic / Entware live emulation inside Docker..."
docker run --rm -i \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  -v "${TACHYON_MOUNT}:/src-tachyon:ro" \
  -v tachyon-core-linux-target:/target-core:ro \
  -v tachyon-rs-linux-target:/target-tachyon:ro \
  "$SIM_IMAGE" \
  bash -s <<'SIM_EOF'
set -euo pipefail

mkdir -p /opt/bin /opt/sbin /opt/etc/init.d /opt/etc/tachyon /opt/etc/tachyon-core \
         /opt/etc/ndm/fs.d /opt/etc/ndm/netfilter.d /opt/etc/ndm/ifstatechanged.d \
         /opt/var/run /tmp/tachyon-rs /tmp/tachyon-core

cp /target-tachyon/debug/tachyon /opt/bin/tachyon
cp /target-core/debug/tachyon-core /opt/bin/tachyon-core
chmod 0755 /opt/bin/tachyon /opt/bin/tachyon-core

# Prefer system iptables (iptables-nft supports TPROXY + REDIRECT + MARK inside modern/WSL2 kernels)
ln -sf "$(command -v ipset)" /opt/sbin/ipset

# Keenetic Entware markers, scripts & mocks
cat > /opt/etc/entware_release <<'EOF'
release=keenetic
arch=x86_64
EOF

cat > /opt/bin/ndmc <<'EOF'
#!/bin/sh
echo "title: KeeneticOS 5.01.C.10.0-0"
echo "model: Keenetic Viva (KN-1913)"
exit 0
EOF
cat > /opt/bin/opkg <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 /opt/bin/ndmc /opt/bin/opkg

cp /src-tachyon/entware/S99tachyon /opt/etc/init.d/S99tachyon
cp /src-tachyon/entware/ndm/netfilter.d/100-tachyon.sh /opt/etc/ndm/netfilter.d/100-tachyon.sh
cp /src-tachyon/entware/ndm/ifstatechanged.d/100-tachyon.sh /opt/etc/ndm/ifstatechanged.d/100-tachyon.sh
cp /src-tachyon/entware/ndm/fs.d/100-tachyon.sh /opt/etc/ndm/fs.d/100-tachyon.sh
chmod 0755 /opt/etc/init.d/S99tachyon /opt/etc/ndm/*/*.sh

# Create dummy LAN bridge br0 matching Keenetic layout
ip link add br0 type dummy
ip addr add 192.168.100.1/24 dev br0
ip link set br0 up

# 1. Verify native AdGuard/hosts -> .trs compilation & CLI match
cat > /tmp/sample-adblock.txt <<'EOF'
||ads.example.com^
@@||ok.ads.example.com^$important
0.0.0.0 telemetry.test
EOF
/opt/bin/tachyon-core rule-set convert-adblock /tmp/sample-adblock.txt --split-tiers /tmp/trs-check
python3 - <<'PY'
from pathlib import Path
for fn in ("adguard-allow-important.trs", "adguard-block.trs"):
    data = Path("/tmp/trs-check", fn).read_bytes()
    assert len(data) >= 96 and data[:4] == b"TSRS", f"Invalid TRS file: {fn}"
print("[OK] AdGuard/hosts --split-tiers compiled valid TSRS v2 .trs tiers")
PY
/opt/bin/tachyon-core rule-set match /tmp/trs-check/adguard-block.trs --domain sub.ads.example.com | grep -q "match"

# Seed tier files in both runtime candidates so compile_core_config wires them as format="trs"
mkdir -p /var/run/tachyon
cp /tmp/trs-check/adguard-*.trs /tmp/tachyon-rs/
cp /tmp/trs-check/adguard-*.trs /var/run/tachyon/

# 2. Configure Tachyon for Keenetic Entware (let AppState::load_or_create seed full defaults first)
export PATH="/opt/bin:/opt/sbin:$PATH"
export TACHYON_DATA_DIR="/opt/etc/tachyon"

/opt/bin/tachyon status >/dev/null 2>&1 || true
python3 - <<'PY'
import json
from pathlib import Path

cfg_path = Path("/opt/etc/tachyon/tachyon.json")
doc = json.loads(cfg_path.read_text(encoding="utf-8"))
doc["settings"].update({
    "listen_addr": "127.0.0.1",
    "listen_port": 1680,
    "core_bin_path": "/opt/bin/tachyon-core",
    "core_config_path": "/opt/etc/tachyon-core/config.json",
    "proxy_mode": "tproxy",
    "entware_dns_mode": "redirect",
    "entware_dns_port": 1053,
    "fakeip_enabled": True,
    "ipv6_mode": "off",
    "dns_type": "udp",
    "dns_servers": ["1.1.1.1"],
    "bootstrap_dns_servers": ["1.1.1.1"],
    "source_network_interfaces": ["br0"],
    "enable_watchdog": False,
})
doc["sections"] = [
    {
        "id": "hosts_block",
        "label": "Hosts Block",
        "enabled": True,
        "action": "direct",
        "dns_hosts": "||inline-ad.example.net^\n0.0.0.0 inline-host.test\n",
    }
]
cfg_path.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
PY

/opt/bin/tachyon daemon >/tmp/tachyon-daemon.log 2>&1 &
DAEMON_PID=$!
trap 'kill "$DAEMON_PID" 2>/dev/null || true' EXIT

# Wait for HTTP API & IPC token (resolve_ram_tmpfs_dir may pick /run/tachyon, /var/run/tachyon, or /tmp/tachyon-rs)
IPC_TOK_PATH=""
for _ in $(seq 1 40); do
  for cand in /tmp/tachyon-rs/ipc.token /run/tachyon/ipc.token /var/run/tachyon/ipc.token /dev/shm/tachyon-rs/ipc.token; do
    if [ -s "$cand" ]; then
      IPC_TOK_PATH="$cand"
      break
    fi
  done
  if [ -n "$IPC_TOK_PATH" ] && curl -sf http://127.0.0.1:1680/cgi-bin/luci >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if [ -z "$IPC_TOK_PATH" ] || [ ! -s "$IPC_TOK_PATH" ]; then
  echo "ERROR: tachyon daemon did not expose ipc.token"
  cat /tmp/tachyon-daemon.log || true
  exit 1
fi

# Give tachyon-core startup + iptables apply up to 15s (calling exact LuCI file.exec RPC path)
IPC_TOK="$(cat "$IPC_TOK_PATH")"
export IPC_TOK
CORE_READY=0
for _ in $(seq 1 30); do
  CORE_READY="$(curl -sf -H "X-Tachyon-Local-Token: $IPC_TOK" -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","file","exec",{"command":"/opt/bin/tachyon","params":["check_tachyon_core"]}]}' \
    http://127.0.0.1:1680/ubus | python3 -c 'import sys,json; out=json.load(sys.stdin)["result"][1]["stdout"]; d=json.loads(out); print(int(bool(d.get("tachyon_core_process_running") and d.get("tachyon_core_ports_listening"))))' 2>/dev/null || echo 0)"
  if [ "$CORE_READY" = "1" ]; then
    break
  fi
  sleep 0.5
done
if [ "$CORE_READY" != "1" ]; then
  echo "WARN: core check not yet ready after 15s; daemon log:"
  tail -n 50 /tmp/tachyon-daemon.log || true
fi

echo "--- Runtime diagnostics verification ---"
python3 - <<'PY'
import json, os, socket, struct, urllib.request

tok = os.environ["IPC_TOK"]

def ubus_exec(cmd_name):
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "call",
        "params": [
            "00000000000000000000000000000000",
            "file",
            "exec",
            {"command": "/opt/bin/tachyon", "params": [cmd_name]},
        ],
    }).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:1680/ubus",
        data=body,
        headers={"Content-Type": "application/json", "X-Tachyon-Local-Token": tok},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        payload = json.loads(resp.read().decode())["result"][1]
        assert payload.get("code", 0) == 0, f"{cmd_name} failed: {payload}"
        return json.loads(payload["stdout"])

# 1. Platform & firewall detection via get_status
status_res = ubus_exec("get_status")
pinfo = status_res.get("platform_info", {})
print("platform_info:", json.dumps(pinfo, ensure_ascii=False))
assert pinfo.get("platform") == "keenetic_entware", f"unexpected platform: {status_res}"
assert pinfo.get("firewall") == "iptables", f"unexpected firewall: {pinfo}"
assert pinfo.get("is_keenetic") is True and pinfo.get("is_entware") is True

# 2. Core health (Fix #1: S99tachyon must not trigger Init.d conflict!)
core_chk = ubus_exec("check_tachyon_core")
print("check_tachyon_core:", json.dumps(core_chk, ensure_ascii=False))
assert core_chk["tachyon_core_installed"] == 1
assert core_chk["tachyon_core_service_exist"] == 1
assert core_chk["tachyon_core_autostart_disabled"] == 1, "false Init.d conflict on S99tachyon!"
assert core_chk["tachyon_core_process_running"] == 1
assert core_chk["tachyon_core_ports_listening"] == 1

# 3. Live UDP FakeIP query directly against 127.0.0.1:1053
txid = b"\x12\x34"
flags = b"\x01\x00"
counts = b"\x00\x01\x00\x00\x00\x00\x00\x00"
qname = b"".join(bytes([len(p)]) + p.encode() for p in "probe.example.com".split(".")) + b"\x00"
pkt = txid + flags + counts + qname + struct.pack("!HH", 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3.0)
sock.sendto(pkt, ("127.0.0.1", 1053))
ans, _ = sock.recvfrom(512)
sock.close()
assert len(ans) >= 16 and ans[:2] == txid, "no valid DNS answer from :1053"
fake_ip = ".".join(str(b) for b in ans[-4:])
print("[OK] Direct UDP DNS probe to 127.0.0.1:1053 returned:", fake_ip)
assert ans[-4] == 198 and ans[-3] in (18, 19), f"expected 198.18.0.0/15 FakeIP, got {fake_ip}"

# 4. check_fakeip (Fix #4: must probe 127.0.0.1:1053 on Entware!)
fakeip_chk = ubus_exec("check_fakeip")
print("check_fakeip:", json.dumps(fakeip_chk, ensure_ascii=False))
assert fakeip_chk.get("fakeip") is True, f"check_fakeip failed: {fakeip_chk}"

# 5. check_dns (Fix #2: must use :1053 & TACHYON_DNS_NAT, not dnsmasq!)
dns_chk = ubus_exec("check_dns")
print("check_dns:", json.dumps(dns_chk, ensure_ascii=False))
assert dns_chk["dns_on_router"] == 1
assert dns_chk["dhcp_config_status"] == 1, f"dhcp_config_status failed on Entware: {dns_chk}"
assert "1053" in (dns_chk.get("dns_router_label") or "")

# 6. check_nft_rules (Fix #3: must inspect iptables TACHYON_* instead of nft!)
ipt_chk = ubus_exec("check_nft_rules")
print("check_nft_rules (summary):", {k: ipt_chk.get(k) for k in (
    "installed", "table_exist", "table_name",
    "rules_mangle_exist", "mangle_rules_count", "mangle_packets",
    "rules_mangle_output_exist", "mangle_output_rules_count", "mangle_output_packets",
    "rules_proxy_exist", "proxy_rules_count", "proxy_packets",
)})
assert ipt_chk["table_exist"] == 1
assert ipt_chk["table_name"] == "iptables (TACHYON_*)"
assert ipt_chk["rules_mangle_exist"] == 1 and ipt_chk["mangle_rules_count"] > 0
assert ipt_chk["rules_mangle_output_exist"] == 1 and ipt_chk["mangle_output_rules_count"] > 0

from pathlib import Path
ipt_targets = Path("/proc/net/ip_tables_targets").read_text() if Path("/proc/net/ip_tables_targets").exists() else ""
if "TPROXY" in ipt_targets:
    assert ipt_chk["rules_proxy_exist"] == 1 and ipt_chk["proxy_rules_count"] > 0, f"TPROXY supported in kernel but proxy rules missing: {ipt_chk}"
else:
    print("[INFO] Host/Docker kernel lacks xt_TPROXY target; mangle/output/nat chains verified directly")

print("=== ALL KEENETIC / ENTWARE EMULATION CHECKS PASSED ===")
PY
SIM_EOF
