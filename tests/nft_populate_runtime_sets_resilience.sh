#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
MOCK_DIR="$WORK_DIR/mock_nft"
NFT_LOG="$WORK_DIR/nft.log"
UCI_STATE="$WORK_DIR/uci.state"

mkdir -p "$WORK_DIR/bin" "$MOCK_DIR"

cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/usr/bin/env bash
set -eo pipefail

MOCK_DIR="${MOCK_NFT_DIR:?}"
NFT_LOG="${MOCK_NFT_LOG:?}"

printf 'nft' >>"$NFT_LOG"
for a in "$@"; do
  printf '\t%s' "$a" >>"$NFT_LOG"
done
printf '\n' >>"$NFT_LOG"

table_file() {
  printf '%s/table_%s' "$MOCK_DIR" "$1"
}

sets_file() {
  printf '%s/sets_%s' "$MOCK_DIR" "$1"
}

elems_file() {
  printf '%s/elems_%s_%s' "$MOCK_DIR" "$1" "$2"
}

has_set() {
  local tbl="$1" set="$2"
  [ -f "$(sets_file "$tbl")" ] && grep -Fxq "$set" "$(sets_file "$tbl")"
}

add_set_record() {
  local tbl="$1" set="$2"
  touch "$(table_file "$tbl")"
  touch "$(sets_file "$tbl")"
  if ! grep -Fxq "$set" "$(sets_file "$tbl")"; then
    printf '%s\n' "$set" >>"$(sets_file "$tbl")"
  fi
}

check_and_record_elements() {
  local tbl="$1" set="$2" raw_csv="$3"
  if ! has_set "$tbl" "$set"; then
    printf 'Error: No such file or directory: set %s in table inet %s\n' "$set" "$tbl" >&2
    return 1
  fi
  if [ "${MOCK_FAIL_ONCE_ADD_ELEMENT:-0}" = "1" ] && [ ! -f "$MOCK_DIR/failed_once" ]; then
    : >"$MOCK_DIR/failed_once"
    printf 'Error: simulated add element failure on existing table\n' >&2
    return 1
  fi
  if [ "${MOCK_FAIL_ON_OVERLAP:-0}" = "1" ]; then
    local ef
    ef="$(elems_file "$tbl" "$set")"
    touch "$ef"
    awk -v ef_path="$ef" -v raw_csv="$raw_csv" '
      function ipv4_num(ip,   parts, i) {
        if (split(ip, parts, ".") != 4) return -1
        for (i = 1; i <= 4; i++) {
          if (parts[i] !~ /^[0-9]+$/ || parts[i] + 0 > 255) return -1
        }
        return ((parts[1] * 16777216) + (parts[2] * 65536) + (parts[3] * 256) + parts[4])
      }
      function parse_rng(tok,   ab, sl, s, e, p, span, i) {
        gsub(/^[ \t]+|[ \t]+$/, "", tok)
        if (tok == "") return 0
        if (index(tok, "-") > 0) {
          split(tok, ab, "-")
          gsub(/^[ \t]+|[ \t]+$/, "", ab[1])
          gsub(/^[ \t]+|[ \t]+$/, "", ab[2])
          s = ipv4_num(ab[1]); e = ipv4_num(ab[2])
          if (s < 0 || e < 0) return 0
          out_s = s; out_e = e; return 1
        }
        if (index(tok, "/") > 0) {
          split(tok, sl, "/")
          s = ipv4_num(sl[1]); p = sl[2] + 0
          if (s < 0 || p < 0 || p > 32) return 0
          span = 1
          for (i = 0; i < 32 - p; i++) span *= 2
          s = int(s / span) * span
          out_s = s; out_e = s + span - 1; return 1
        }
        s = ipv4_num(tok)
        if (s < 0) return 0
        out_s = s; out_e = s; return 1
      }
      BEGIN {
        n_ex = 0
        while ((getline line < ef_path) > 0) {
          if (split(line, f, /[ \t]+/) == 2) {
            n_ex++
            ex_s[n_ex] = f[1] + 0
            ex_e[n_ex] = f[2] + 0
          }
        }
        close(ef_path)
        n_tok = split(raw_csv, toks, ",")
        n_new = 0
        for (i = 1; i <= n_tok; i++) {
          if (!parse_rng(toks[i])) continue
          for (j = 1; j <= n_ex; j++) {
            if (out_s <= ex_e[j] && out_e >= ex_s[j]) {
              printf "Error: conflicting intervals specified: %s\n", toks[i] > "/dev/stderr"
              exit 1
            }
          }
          n_new++
          new_s[n_new] = out_s
          new_e[n_new] = out_e
        }
        for (i = 1; i <= n_new; i++) {
          printf "%.0f %.0f\n", new_s[i], new_e[i] >> ef_path
        }
        close(ef_path)
      }
    '
  fi
  return 0
}

exec_nft_line() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  [ -z "$line" ] && return 0

  if [[ "$line" =~ ^add\ table\ inet\ ([^[:space:]]+)$ ]]; then
    touch "$(table_file "${BASH_REMATCH[1]}")"
    touch "$(sets_file "${BASH_REMATCH[1]}")"
    return 0
  fi
  if [[ "$line" =~ ^delete\ table\ inet\ ([^[:space:]]+)$ ]]; then
    rm -f "$(table_file "${BASH_REMATCH[1]}")" "$(sets_file "${BASH_REMATCH[1]}")" "$MOCK_DIR/elems_${BASH_REMATCH[1]}"_*
    : >"$MOCK_DIR/table_rebuilt"
    return 0
  fi
  if [[ "$line" =~ ^add\ set\ inet\ ([^[:space:]]+)\ ([^[:space:]]+)\  ]]; then
    add_set_record "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$line" =~ ^flush\ set\ inet\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
    local tbl="${BASH_REMATCH[1]}" set="${BASH_REMATCH[2]}"
    if ! has_set "$tbl" "$set"; then
      printf 'Error: missing set %s in flush\n' "$set" >&2
      return 1
    fi
    rm -f "$(elems_file "$tbl" "$set")"
    return 0
  fi
  if [[ "$line" =~ ^add\ element\ inet\ ([^[:space:]]+)\ ([^[:space:]]+)\ \{\ (.*)\ \}$ ]]; then
    check_and_record_elements "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return $?
  fi
  return 0
}

if [ "$1" = "-f" ] && [ -f "$2" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    exec_nft_line "$line"
  done <"$2"
  exit 0
fi

if [ "$1" = "list" ] && [ "$2" = "tables" ]; then
  for f in "$MOCK_DIR"/table_*; do
    [ -e "$f" ] || continue
    printf 'table inet %s\n' "${f##*/table_}"
  done
  exit 0
fi

if [ "$1" = "list" ] && [ "$2" = "table" ] && [ "$3" = "inet" ]; then
  tbl="$4"
  if [ ! -f "$(table_file "$tbl")" ]; then
    exit 1
  fi
  printf 'table inet %s {\n}\n' "$tbl"
  exit 0
fi

if [ "$1" = "-j" ] && [ "$2" = "-t" ] && [ "$3" = "list" ] && [ "$4" = "table" ] && [ "$5" = "inet" ]; then
  tbl="$6"
  if [ ! -f "$(table_file "$tbl")" ]; then
    exit 1
  fi
  printf '{"nftables":[{"table":{"family":"inet","name":"%s"}}' "$tbl"
  if [ -f "$(sets_file "$tbl")" ]; then
    while IFS= read -r s || [ -n "$s" ]; do
      [ -n "$s" ] || continue
      printf ',{"set":{"family":"inet","name":"%s","table":"%s","type":"ipv4_addr","flags":["interval"]}}' "$s" "$tbl"
    done <"$(sets_file "$tbl")"
  fi
  printf ']}\n'
  exit 0
fi

exec_nft_line "$*"
EOF_NFT
chmod +x "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/bin/ip" <<'EOF_IP'
#!/usr/bin/env bash
if [ "$1" = "route" ] && [ "$2" = "show" ]; then
  printf 'local default dev lo scope host\n'
  exit 0
fi
if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "show" ]; then
  printf 'local default dev lo metric 1024 pref medium\n'
  exit 0
fi
if [ "$1" = "-4" ] && [ "$2" = "rule" ] && [ "$3" = "show" ]; then
  printf '105:\tfrom all fwmark 0x04000000/0x04000000 lookup TachyonTable\n'
  exit 0
fi
exit 0
EOF_IP
chmod +x "$WORK_DIR/bin/ip"

export PATH="$WORK_DIR/bin:$PATH"
export MOCK_NFT_DIR="$MOCK_DIR"
export MOCK_NFT_LOG="$NFT_LOG"

seed_existing_table_base_sets() {
  rm -rf "$MOCK_DIR"
  mkdir -p "$MOCK_DIR"
  : >"$NFT_LOG"
  touch "$MOCK_DIR/table_TachyonTable"
  cat >"$MOCK_DIR/sets_TachyonTable" <<'EOF_SETS'
tachyon_subnets
tachyon_subnets6
tachyon_ports
tachyon_ip_ports
tachyon_ip6_ports
tachyon_interfaces
localv4
localv6
EOF_SETS
}

# Scenario A: Priority section (bypass + source_ip) + source-aware DNS when TachyonTable exists
# WITHOUT tachyon_rule_* priority sets or tachyon_dns_sources yet.
seed_existing_table_base_sets
cat >"$UCI_STATE" <<'EOF_UCI_A'
tachyon.settings=settings
tachyon.settings.proxy_mode=tproxy
tachyon.settings.source_network_interfaces=br-lan
tachyon.sec_prio=section
tachyon.sec_prio.enabled=1
tachyon.sec_prio.action=bypass
tachyon.sec_prio.priority=10
tachyon.sec_prio.source_ip=192.168.1.50
tachyon.sec_prio.ip_cidr=203.0.113.0/24
tachyon.sec_dns=section
tachyon.sec_dns.enabled=1
tachyon.sec_dns.action=dns
tachyon.sec_dns.fully_routed_ips=192.168.1.60
EOF_UCI_A

TACHYON_FORCE_NFT_BATCH=1 \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-populate-runtime-sets-from-uci \
  1 "" TachyonTable tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces localv4 0x04000000 tachyon_subnets6 tachyon_ip6_ports localv6 \
  || fail "Scenario A failed: missing priority/DNS source sets on existing table"

grep -Fxq "tachyon_dns_sources" "$MOCK_DIR/sets_TachyonTable" \
  || fail "Scenario A did not create missing tachyon_dns_sources set"
grep -Eq '^tachyon_rule_.*_subnets$' "$MOCK_DIR/sets_TachyonTable" \
  || fail "Scenario A did not create missing priority subnets set"

# Scenario B: Overlapping IPv4 subnets exceeding TACHYON_NFT_CHUNK_SIZE=100 must merge before chunking
# so mock nft never sees conflicting intervals split across chunks.
seed_existing_table_base_sets
{
  printf 'tachyon.settings=settings\n'
  printf 'tachyon.settings.proxy_mode=tproxy\n'
  printf 'tachyon.settings.source_network_interfaces=br-lan\n'
  printf 'tachyon.sec_overlap=section\n'
  printf 'tachyon.sec_overlap.enabled=1\n'
  printf 'tachyon.sec_overlap.action=connection\n'
  cidrs=""
  for i in $(seq 1 110); do
    cidrs="${cidrs} 10.${i}.0.0/24"
  done
  # Overlapping single IP that originally follows >100 entries (would sit in chunk #2 without merge)
  cidrs="${cidrs} 10.1.0.42/32"
  printf 'tachyon.sec_overlap.ip_cidr=%s\n' "${cidrs# }"
} >"$UCI_STATE"

MOCK_FAIL_ON_OVERLAP=1 \
  TACHYON_FORCE_NFT_BATCH=1 \
  TACHYON_NFT_CHUNK_SIZE=100 \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-populate-runtime-sets-from-uci \
  1 "" TachyonTable tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces localv4 0x04000000 tachyon_subnets6 tachyon_ip6_ports localv6 \
  || fail "Scenario B failed: overlapping IPv4 subnets across chunks were rejected"

# Scenario C: First add element fails on stale existing table; single recovery rebuild + retry succeeds.
seed_existing_table_base_sets
cat >"$UCI_STATE" <<'EOF_UCI_C'
tachyon.settings=settings
tachyon.settings.proxy_mode=tun
tachyon.settings.source_network_interfaces=br-lan
tachyon.sec_main=section
tachyon.sec_main.enabled=1
tachyon.sec_main.action=connection
tachyon.sec_main.ip_cidr=198.51.100.0/24
EOF_UCI_C

MOCK_FAIL_ONCE_ADD_ELEMENT=1 \
  TACHYON_FORCE_NFT_BATCH=1 \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-populate-runtime-sets-from-uci \
  1 "" TachyonTable tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces localv4 0x04000000 tachyon_subnets6 tachyon_ip6_ports localv6 \
  || fail "Scenario C failed: recovery rebuild on failed batch update did not succeed"

[ -f "$MOCK_DIR/failed_once" ] || fail "Scenario C setup error: first failure was not triggered"
[ -f "$MOCK_DIR/table_rebuilt" ] || fail "Scenario C did not trigger table rebuild after first failure"

printf 'nft_populate_runtime_sets_resilience tests passed\n'
