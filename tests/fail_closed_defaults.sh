#!/usr/bin/env bash
# End to end: the shipped /etc/config/tachyon, untouched, plus one Fail-Closed
# section must produce every Fail-Closed protection with no other setting
# changed. Each check reads what the real code generates (nft commands, ip
# rules, core config), not the options themselves.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SHIPPED="$ROOT_DIR/tachyon/files/etc/config/tachyon"
NFT_UC="$TACHYON_LIB/nft/apply.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to read the shipped config"

# The shipped config -> UCI state lines and a generator fixture, plus a
# Fail-Closed section with an IP list.
python3 - "$SHIPPED" "$WORK_DIR/state" "$WORK_DIR/fixture.json" "${1:-}" <<'PY'
import json, re, sys
src, state_path, fixture_path, extra = sys.argv[1:5]
sections, cur = [], None
for raw in open(src, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    m = re.match(r"config\s+(\S+)(?:\s+'?([^']*)'?)?$", line)
    if m:
        cur = {".type": m.group(1), ".name": m.group(2) or "cfg%d" % len(sections)}
        sections.append(cur)
        continue
    m = re.match(r"(option|list)\s+(\S+)\s+'?([^']*)'?$", line)
    if m and cur is not None:
        kind, key, val = m.groups()
        if kind == "list":
            cur.setdefault(key, []).append(val)
        else:
            cur[key] = val
# A bypass section with a stale fail_policy=block (left after an action change):
# ignored, while the real Fail-Closed section below still turns everything on.
sections.append({".type": "section", ".name": "ru_direct", "enabled": "1", "action": "bypass",
                 "fail_policy": "block", "ip_cidr": ["198.51.100.0/24"]})
sections.append({".type": "section", ".name": "vpn", "enabled": "1", "action": "proxy",
                 "fail_policy": "block", "ip_cidr": ["203.0.113.0/24"],
                 "selector_proxy_links": ["vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"]})
for kv in filter(None, extra.split(",")):
    k, v = kv.split("=", 1)
    next(s for s in sections if s[".type"] == "settings")[k] = v
with open(state_path, "w") as f:
    for s in sections:
        f.write("tachyon.%s=%s\n" % (s[".name"], s[".type"]))
        for k, v in s.items():
            if not k.startswith("."):
                f.write("tachyon.%s.%s=%s\n" % (s[".name"], k, " ".join(v) if isinstance(v, list) else v))
fixture = {}
for s in sections:
    if s[".type"] == "settings":
        fixture["settings"] = s
    else:
        fixture.setdefault(s[".type"], []).append(s)
json.dump(fixture, open(fixture_path, "w"))
PY
export TACHYON_UCI_STATE_FILE="$WORK_DIR/state"

# --- 1. veto, auto protections and the TUN kill-switch, from the UCI state ----
ucode -L "$TACHYON_LIB" -e '
let ks = require("service.kill_switch");
let uci = require("core.uci");
let settings = uci.get_all("tachyon", "settings");
let sections = uci.section_objects("tachyon", "section");
function check(ok, msg) { if (!ok) die("default: " + msg + "\n"); }
check(settings.emergency_direct_bypass == "1", "shipped emergency_direct_bypass changed; this test assumes the stored 1");
check(ks.uci_veto() == "fail_policy=block: vpn", "Fail-Closed does not veto direct fallback (Emergency Direct Bypass not forced off)");
check(ks.dns_intercept_effective(settings, true), "LAN DNS intercept is not on");
check(ks.webrtc_protect_effective(settings, true), "WebRTC protection is not on");
let tun = {}; for (let k, v in settings) tun[k] = v; tun.proxy_mode = "tun";
check(length(ks.tun_guard_rules(tun, sections, true)) > 0, "TUN kill-switch is not on by default");
' || fail "Fail-Closed defaults are not all on"

# --- 2. nft runtime from UCI, shipped proxy_mode (tproxy) ---------------------
NFT_LOG="$WORK_DIR/nft.log"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT_STUB'
#!/usr/bin/env bash
{ printf 'nft'; for arg in "$@"; do printf '\t%s' "$arg"; [ -f "$arg" ] && { printf '\t'; tr '\n' ' ' <"$arg"; }; done; printf '\n'; } >> "${NFT_LOG:?}"
exit 0
NFT_STUB
chmod +x "$WORK_DIR/bin/nft"
export NFT_LOG
PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$NFT_UC" nft-create-runtime-base-from-uci \
  TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces 0x00100000 0x00200000 >/dev/null ||
  fail "nft runtime from the shipped config failed"
PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$NFT_UC" nft-add-section-priority-rules-fixture "$WORK_DIR/fixture.json" \
  TachyonTable tachyon_interfaces localv4 localv6 0x00100000 >/dev/null || fail "section rules from the shipped config failed"
need() { grep -Fq -- "$1" "$NFT_LOG" || fail "default: $2"; }
need 'tachyon-dns-intercept' "LAN DNS (53) is not redirected to the router"
need $'th\tdport\t853' "DNS-over-TLS (853) is not refused"
need $'daddr\t1.1.1.1/32\tmeta\tmark\tset' "DoH by address is not blocked"
need 'tachyon-webrtc-leak-guard' "WebRTC STUN/TURN is not dropped"
need 'tachyon-fail-closed-forward' "marked packets reaching forward are not dropped"
need 'tachyon-fail-closed-other-l4' "ping/GRE/ESP to the section's IPs is not dropped"
need 'tachyon-inbound-reply' "inbound replies (port forwards) are intercepted"
need 'tachyon_rule_vpn_subnets' "the Fail-Closed section's IP rules are missing"
if grep -F 'tachyon-fail-closed-other-l4' "$NFT_LOG" | grep -Fq 'ru_direct'; then
  fail "the bypass section with a stale fail_policy got Fail-Closed rules"
fi
grep -F 'priority_rules' "$NFT_LOG" | grep -F 'tachyon_rule_ru_direct_subnets' | grep -Fq $'counter\taccept' ||
  fail "the bypass section next to a Fail-Closed one no longer goes direct"

# --- 3. core config: DoH by name and the canaries, DoH reject ----------------
mkdir -p "$WORK_DIR/core.json.section-cache"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/core.json" 127.0.0.1 >/dev/null 2>"$WORK_DIR/gen.err" ||
  fail "generator rejected the shipped config: $(tail -3 "$WORK_DIR/gen.err")"
ucode -e '
let c = json(require("fs").readfile(ARGV[0]));
function arr(v) { return type(v) == "array" ? v : (v == null ? [] : [ v ]); }
function nx(name) {
    for (let r in (c.dns || {}).rules || [])
        if (r.action == "predefined" && r.rcode == "NXDOMAIN" && index(arr(r.domain_suffix), name) >= 0) return true;
    return false;
}
for (let n in [ "dns.google", "cloudflare-dns.com", "use-application-dns.net", "mask.icloud.com" ])
    if (!nx(n)) die("default: " + n + " is not answered NXDOMAIN\n");
let doh = false;
for (let r in (c.route || {}).rules || [])
    if (r.action == "reject" && index(arr(r.ip_cidr), "1.1.1.1/32") >= 0) doh = true;
if (!doh) die("default: the core does not reject DoH by address\n");
' "$WORK_DIR/core.json" || fail "core config from the shipped defaults lacks Fail-Closed DoH blocking"

printf 'PASS: fail_closed_defaults\n'
