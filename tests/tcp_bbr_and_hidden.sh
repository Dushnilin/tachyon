#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"
  grep -Fq "$expected" "$file" || fail "$label: expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local label="$3"
  if grep -Fq "$unexpected" "$file"; then
    fail "$label: did not expect '$unexpected' in $file"
  fi
}

VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
NFT_APPLY_UC="$TACHYON_LIB/nft/apply.uc"
DEFAULT_UCI="$ROOT_DIR/tachyon/files/etc/config/tachyon"

# 1. Default config schema and common.is_tcp_bbr_enabled
grep -Eq "option[[:space:]]+tcp_bbr[[:space:]]+'1'" "$DEFAULT_UCI" ||
  fail "default /etc/config/tachyon must enable tcp_bbr '1'"

ucode -S -L "$TACHYON_LIB" -e '
let common = require("core.common");
if (!common.is_tcp_bbr_enabled({})) exit(1);
if (!common.is_tcp_bbr_enabled({ tcp_bbr: "1" })) exit(1);
if (common.is_tcp_bbr_enabled({ tcp_bbr: "0" })) exit(1);
if (common.is_tcp_bbr_enabled({ tcp_bbr: false })) exit(1);
' || fail "common.is_tcp_bbr_enabled behavior mismatch"

# 2. Validator tests for settings.tcp_bbr and hidden flags (#405)
write_hidden_bbr_fixture() {
  local out="$1"
  local tcp_bbr_val="$2"
  local sec_hidden="$3"
  local src_hidden="$4"
  local sub_hidden="$5"
  cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "service_listen_address": "127.0.0.1",
    "tcp_bbr": "${tcp_bbr_val}"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "hidden": "${sec_hidden}",
      "selector_proxy_links": [ "vless://11111111-1111-4111-8111-111111111111@198.51.100.47:443?encryption=none#n1" ],
      "domain_suffix": [ "example.com" ]
    }
  ],
  "outbound_source": [
    {
      ".name": "src_1",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "Hidden Source",
      "source_type": "proxy_links",
      "hidden": "${src_hidden}",
      "proxy_links": [ "vless://11111111-1111-4111-8111-111111111111@198.51.100.47:443?encryption=none#n2" ]
    }
  ],
  "subscription_url": [
    {
      ".name": "sub_1",
      ".type": "subscription_url",
      "enabled": "1",
      "url": "https://example.com/sub",
      "hidden": "${sub_hidden}"
    }
  ]
}
JSON
}

for b in 0 1; do
  for h in 0 1; do
    write_hidden_bbr_fixture "$WORK_DIR/val-ok-$b-$h.json" "$b" "$h" "$h" "$h"
    ucode -S -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val-ok-$b-$h.json" '{}' >/dev/null ||
      fail "validator rejected valid tcp_bbr=$b hidden=$h fixture"
  done
done

write_hidden_bbr_fixture "$WORK_DIR/val-bad-bbr.json" "yes_please" "0" "0" "0"
if ucode -S -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val-bad-bbr.json" '{}' >/dev/null 2>&1; then
  fail "validator must reject invalid settings.tcp_bbr"
fi

write_hidden_bbr_fixture "$WORK_DIR/val-bad-sec-hidden.json" "1" "maybe" "0" "0"
if ucode -S -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val-bad-sec-hidden.json" '{}' >/dev/null 2>&1; then
  fail "validator must reject invalid section.hidden"
fi

write_hidden_bbr_fixture "$WORK_DIR/val-bad-src-hidden.json" "1" "0" "maybe" "0"
if ucode -S -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val-bad-src-hidden.json" '{}' >/dev/null 2>&1; then
  fail "validator must reject invalid outbound_source.hidden"
fi

write_hidden_bbr_fixture "$WORK_DIR/val-bad-sub-hidden.json" "1" "0" "0" "maybe"
if ucode -S -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val-bad-sub-hidden.json" '{}' >/dev/null 2>&1; then
  fail "validator must reject invalid subscription_url.hidden"
fi

# 3. Hidden section/source stays active in generated outbounds
ucode -S -L "$TACHYON_LIB" -e '
let connections = require("config.connections");
let generator = require("tachyon_core.generator_outbounds");

let captured_state = null;
generator.init({
    runtime_settings: function() { return {}; },
    is_sb_1_14_plus: function() { return true; },
    atomic_write_json_file: function(_path, state) { captured_state = state; return true; },
    routes: {
        section_needs_country_is: function() { return false; },
        section_has_direct_priority_level: function() { return false; },
        add_proxy_selector: function() { return null; },
        urltest_outbound_tag: function(n, p) { return p + "-" + n; },
        urltest_idle_timeout: function() { return ""; }
    },
    runtime_generate_unsupported: function(msg) { die("unexpected error: " + msg + "\n"); }
});

connections.set_item_sections_from_data({
    outbound_source: [
        {
            ".name": "src_hidden_1",
            ".type": "outbound_source",
            enabled: "1",
            hidden: "1",
            name: "Hidden Source",
            source_type: "proxy_links",
            proxy_links: [ "mierus://default:dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ%3D@198.51.100.47?port=2012-2022&protocol=TCP&traffic-pattern=GgQIARAK#HiddenMieru" ]
        }
    ]
});

let cfg = { outbounds: [], endpoints: [] };
generator.add_connections_outbound(cfg, {
    ".name": "HiddenSec",
    ".type": "section",
    enabled: "1",
    hidden: "1",
    action: "connection",
    outbound_source_refs: [ "src_hidden_1" ]
}, {});
connections.set_item_sections_from_data({});

let found_mieru = false;
for (let ob in cfg.outbounds) {
    if (ob.type == "mieru" && ob.server == "198.51.100.47")
        found_mieru = true;
}
if (!found_mieru || !captured_state || length(captured_state.urltestCandidateTags) != 1)
    die("hidden section/outbound_source must remain in config and urltestCandidateTags\n");
' || fail "hidden section/source must stay active in core outbound generation"

# 4. nft/apply.uc apply_tcp_bbr_tuning mocks (fq, fq_codel fallback, unavailable bbr, disable->cubic)
mkdir -p "$WORK_DIR/bin"
UCI_STATE="$WORK_DIR/uci.state"
SYSCTL_LOG="$WORK_DIR/sysctl.log"
MODPROBE_LOG="$WORK_DIR/modprobe.log"
BBR_CONF="$WORK_DIR/etc/sysctl.d/99-tachyon-bbr.conf"
AVAIL_CC="$WORK_DIR/proc_tcp_avail_cc"
MOCK_MODE_FILE="$WORK_DIR/mock_mode"

cat >"$WORK_DIR/bin/modprobe" <<'SH'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "$*" >> "${MODPROBE_LOG:?}"
mode="$(cat "${MOCK_MODE_FILE:?}" 2>/dev/null || echo "")"
if [ "$1" = "tcp_bbr" ] && [ "$mode" = "load_bbr_on_modprobe" ]; then
  printf 'cubic reno bbr\n' > "${AVAIL_CC:?}"
fi
exit 0
SH
chmod 0755 "$WORK_DIR/bin/modprobe"

cat >"$WORK_DIR/bin/sysctl" <<'SH'
#!/usr/bin/env bash
set -eo pipefail
mode="$(cat "${MOCK_MODE_FILE:?}" 2>/dev/null || echo "")"
if [ "$1" = "-n" ]; then
  if [ "$2" = "net.core.default_qdisc" ]; then
    cat "${MOCK_CUR_QDISC_FILE:?}" 2>/dev/null || echo "fq_codel"
  elif [ "$2" = "net.ipv4.tcp_congestion_control" ]; then
    cat "${MOCK_CUR_CC_FILE:?}" 2>/dev/null || echo "cubic"
  else
    echo "0"
  fi
  exit 0
fi
printf '%s\n' "$*" >> "${SYSCTL_LOG:?}"
if [ "$1" = "-w" ] && [ "$2" = "net.core.default_qdisc=fq" ] && [ "$mode" = "no_fq" ]; then
  exit 1
fi
exit 0
SH
chmod 0755 "$WORK_DIR/bin/sysctl"

cat >"$WORK_DIR/bin/ip" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "$WORK_DIR/bin/ip"

cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "$WORK_DIR/bin/logger"

MOCK_CUR_QDISC_FILE="$WORK_DIR/cur_qdisc"
MOCK_CUR_CC_FILE="$WORK_DIR/cur_cc"
export PATH="$WORK_DIR/bin:$PATH"
export UCI_STATE TACHYON_UCI_STATE_FILE="$UCI_STATE" SYSCTL_LOG MODPROBE_LOG
export TACHYON_SYSCTL_BBR_CONF="$BBR_CONF" TACHYON_PROC_TCP_AVAIL_CC="$AVAIL_CC"
export AVAIL_CC MOCK_MODE_FILE MOCK_CUR_QDISC_FILE MOCK_CUR_CC_FILE

write_bbr_uci() {
  cat >"$UCI_STATE" <<EOF
tachyon.settings=tachyon
tachyon.settings.enabled=1
tachyon.settings.tcp_bbr=$1
EOF
}

# 4a: tcp_bbr=1, bbr loaded by modprobe tcp_bbr, fq supported
write_bbr_uci "1"
echo "load_bbr_on_modprobe" >"$MOCK_MODE_FILE"
echo "cubic reno" >"$AVAIL_CC"
echo "fq_codel" >"$MOCK_CUR_QDISC_FILE"
echo "cubic" >"$MOCK_CUR_CC_FILE"
rm -f "$SYSCTL_LOG" "$MODPROBE_LOG" "$BBR_CONF"

ucode -S -L "$TACHYON_LIB" "$NFT_APPLY_UC" apply-connection-tuning >/dev/null
assert_contains "$MODPROBE_LOG" "tcp_bbr" "4a modprobe tcp_bbr"
assert_contains "$MODPROBE_LOG" "sch_fq" "4a modprobe sch_fq"
assert_contains "$SYSCTL_LOG" "net.core.default_qdisc=fq" "4a qdisc fq"
assert_contains "$SYSCTL_LOG" "net.ipv4.tcp_congestion_control=bbr" "4a cc bbr"
assert_contains "$BBR_CONF" "net.core.default_qdisc=fq" "4a conf qdisc"
assert_contains "$BBR_CONF" "net.ipv4.tcp_congestion_control=bbr" "4a conf bbr"

# 4b: Flash-wear protection (unchanged conf must not rewrite mtime)
touch -d '2020-01-01 00:00:00 UTC' "$BBR_CONF"
before_mtime="$(stat -c '%Y' "$BBR_CONF")"
echo "fq" >"$MOCK_CUR_QDISC_FILE"
echo "bbr" >"$MOCK_CUR_CC_FILE"
ucode -S -L "$TACHYON_LIB" "$NFT_APPLY_UC" apply-connection-tuning >/dev/null
after_mtime="$(stat -c '%Y' "$BBR_CONF")"
[ "$before_mtime" = "$after_mtime" ] || fail "flash-wear violation: 99-tachyon-bbr.conf rewritten when unchanged"

# 4c: Stock OpenWrt without sch_fq -> falls back to fq_codel cleanly
echo "no_fq" >"$MOCK_MODE_FILE"
echo "cubic reno bbr" >"$AVAIL_CC"
echo "fq_codel" >"$MOCK_CUR_QDISC_FILE"
echo "cubic" >"$MOCK_CUR_CC_FILE"
rm -f "$SYSCTL_LOG" "$BBR_CONF"

ucode -S -L "$TACHYON_LIB" "$NFT_APPLY_UC" apply-connection-tuning >/dev/null
assert_contains "$SYSCTL_LOG" "net.ipv4.tcp_congestion_control=bbr" "4c bbr enabled with fq_codel"
assert_contains "$BBR_CONF" "net.core.default_qdisc=fq_codel" "4c fallback conf qdisc=fq_codel"
assert_contains "$BBR_CONF" "net.ipv4.tcp_congestion_control=bbr" "4c fallback conf bbr"

# 4d: Kernel lacks BBR even after modprobe -> skip silently and remove stale conf
echo "no_bbr" >"$MOCK_MODE_FILE"
echo "cubic reno" >"$AVAIL_CC"
printf 'stale\n' >"$BBR_CONF"
rm -f "$SYSCTL_LOG"

ucode -S -L "$TACHYON_LIB" "$NFT_APPLY_UC" apply-connection-tuning >/dev/null
[ ! -f "$BBR_CONF" ] || fail "4d stale 99-tachyon-bbr.conf must be removed when kernel lacks BBR"
assert_not_contains "$SYSCTL_LOG" "tcp_congestion_control=bbr" "4d must not set bbr when unavailable"

# 4e: tcp_bbr=0 -> restore cubic + fq_codel and remove conf
write_bbr_uci "0"
echo "fq" >"$MOCK_CUR_QDISC_FILE"
echo "bbr" >"$MOCK_CUR_CC_FILE"
printf 'stale\n' >"$BBR_CONF"
rm -f "$SYSCTL_LOG"

ucode -S -L "$TACHYON_LIB" "$NFT_APPLY_UC" apply-connection-tuning >/dev/null
[ ! -f "$BBR_CONF" ] || fail "4e 99-tachyon-bbr.conf must be removed when tcp_bbr=0"
assert_contains "$SYSCTL_LOG" "net.ipv4.tcp_congestion_control=cubic" "4e restore cubic"
assert_contains "$SYSCTL_LOG" "net.core.default_qdisc=fq_codel" "4e restore fq_codel"

# 5. install.sh ensure_tcp_bbr_best_effort best-effort + flash-safe check
(
  DRY_RUN=0
  TACHYON_INSTALLER_TEST=1
  . "$ROOT_DIR/install.sh"
  msg() { printf 'MSG: %s\n' "$*" >>"$WORK_DIR/inst.log"; }
  warn() { printf 'WARN: %s\n' "$*" >>"$WORK_DIR/inst.log"; }
  command_exists() { [ "$1" = "uci" ]; }
  uci() { echo "1"; }

  # Case 5a: kmod-tcp-bbr unavailable -> non-fatal warning, no conf written
  rm -f "$WORK_DIR/inst_bbr.conf" "$WORK_DIR/inst.log"
  echo "cubic reno" >"$AVAIL_CC"
  echo "no_bbr" >"$MOCK_MODE_FILE"
  ensure_package() { return 1; }
  TACHYON_SYSCTL_BBR_CONF="$WORK_DIR/inst_bbr.conf" ensure_tcp_bbr_best_effort || fail "install.sh must remain non-fatal if kmod-tcp-bbr is absent"
  [ ! -f "$WORK_DIR/inst_bbr.conf" ] || fail "install.sh must not write bbr conf when bbr unavailable"
  assert_contains "$WORK_DIR/inst.log" "kmod-tcp-bbr is unavailable" "5a warning logged"

  # Case 5b: kmod-tcp-bbr installs bbr, fq fails -> writes fq_codel + write_if_changed idempotence
  echo "no_fq" >"$MOCK_MODE_FILE"
  ensure_package() {
    printf 'cubic reno bbr\n' >"$AVAIL_CC"
    return 0
  }
  TACHYON_SYSCTL_BBR_CONF="$WORK_DIR/inst_bbr.conf" ensure_tcp_bbr_best_effort || fail "5b failed"
  assert_contains "$WORK_DIR/inst_bbr.conf" "net.core.default_qdisc=fq_codel" "5b qdisc fallback"
  assert_contains "$WORK_DIR/inst_bbr.conf" "net.ipv4.tcp_congestion_control=bbr" "5b bbr line"

  touch -d '2020-01-01 00:00:00 UTC' "$WORK_DIR/inst_bbr.conf"
  b_ts="$(stat -c '%Y' "$WORK_DIR/inst_bbr.conf")"
  TACHYON_SYSCTL_BBR_CONF="$WORK_DIR/inst_bbr.conf" ensure_tcp_bbr_best_effort
  a_ts="$(stat -c '%Y' "$WORK_DIR/inst_bbr.conf")"
  [ "$b_ts" = "$a_ts" ] || fail "install.sh write_if_changed rewrote unchanged file"
)

printf 'tcp_bbr and hidden tests PASSED!\n'
