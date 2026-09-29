#!/usr/bin/env bash
# FAULT: which migration runs for which legacy config.
#
# Tachyon is a fork of forkop, and that turns the obvious detection heuristic
# inside out. The original test looked for Tachyon's own markers - config_version
# or applied_migrations - and treated their presence as "this is a native Tachyon
# config", excluding only four legacy markers.
#
# But those markers are forkop's too. Its shipped config carries
# `option config_version '1.0.5'` and `list applied_migrations 'interface_sections'`,
# both forked from the same lineage, and a diff of the two default configs shows
# forkop introducing no option Tachyon lacks. So every forkop install detected
# as "tachyon", skipped the migration, and printed "Detected format: Tachyon" -
# a confident false answer to someone deciding whether to trust the import.
#
# The fixtures below reproduce the option sets of the real upstream defaults
# (podkop 0.7.22, forkop 1.0.5, netshift 0.9.9). They are hand-written rather
# than vendored, so the test carries no upstream code.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

# --- forkop 1.0.5: our sibling fork, shaped like us ------------------------
# config_version and applied_migrations present (forkop's own), none of the four
# markers the old code excluded. This is the config that broke.
cat > "$WORK_DIR/forkop" <<'EOF'
config settings 'settings'
	option config_version '1.0.5'
	list applied_migrations 'interface_sections'
	list applied_migrations 'enable_component_checks'
	list applied_migrations 'http_connection_urls'
	option dns_type 'udp'
	list dns_server '77.88.8.8'
	list bootstrap_dns_server '77.88.8.8'
	option dns_check_interval '10s'
	option dns_rewrite_ttl '60'
	option dns_strategy 'prefer_ipv4'
	option dns_detour_enabled '0'
	list source_network_interfaces 'br-lan'
	option enable_output_network_interface '0'
	option shutdown_correctly '0'
	option download_lists_via_proxy '0'
	option update_interval '1d'
	#config subscription_url
EOF

# --- podkop 0.7.22: genuinely legacy shape ----------------------------------
cat > "$WORK_DIR/podkop" <<'EOF'
config settings 'settings'
	option dns_type 'udp'
	option dns_server '77.88.8.8'
	option bootstrap_dns_server '77.88.8.8'
	option dns_rewrite_ttl '60'
	list source_network_interfaces 'br-lan'
	option enable_output_network_interface '0'
	option do_not_touch_dhcp '0'
	option download_lists_via_proxy '0'
	option update_interval '1d'
config section 'main'
	option connection_type 'proxy'
	option proxy_config_type 'url'
	option proxy_string ''
	option enable_udp_over_tcp '0'
	list community_lists 'russia_inside'
EOF

# --- netshift 0.9.9: legacy shape plus extra markers -------------------------
cat > "$WORK_DIR/netshift" <<'EOF'
config settings 'settings'
	option dns_type 'udp'
	option dns_server '77.88.8.8'
	option dns_via_outbound '1'
	option global_proxy '1'
	option enable_ipv6 '0'
	option exclude_bittorrent '0'
	option dns_client_subnet '0'
	option sing_box_extended_arm_build '0'
config section 'main'
	option connection_type 'proxy'
	option proxy_config_type 'url'
	option proxy_string ''
	option enable_udp_over_tcp '0'
	list community_lists 'russia_inside'
EOF

# --- a native Tachyon config ------------------------------------------------
cat > "$WORK_DIR/tachyon" <<'EOF'
config settings 'settings'
	option config_version '1.0.5'
	list applied_migrations 'interface_sections'
	list applied_migrations 'enable_component_checks'
	list applied_migrations 'http_connection_urls'
	list applied_migrations 'dns_hosts_to_option'
	list applied_migrations 'global_hosts_to_section'
	option dns_type 'udp'
	list dns_server '77.88.8.8'
	option dns_rewrite_ttl '60'
EOF

# A native config that uses community subnets. community_lists was briefly
# considered as a legacy marker; Tachyon supports the option, so that would have
# misclassified this file and run the legacy conversion over a current config.
cat > "$WORK_DIR/tachyon-native-community" <<'EOF'
config settings 'settings'
	option config_version '1.0.5'
	list applied_migrations 'interface_sections'
	option dns_type 'udp'
config rule 'with_community'
	option enabled '1'
	option action 'outbound'
	list community_lists 'russia_inside'
EOF

detect() {
  # Exported, and read with getenv: ucode runs in its own process and cannot
  # see shell variables. Referencing bare D/F silently evaluated to nothing, so
  # every case collapsed onto the same empty path.
  TACHYON_DETECT_DIR="$WORK_DIR" TACHYON_DETECT_FILE="$1" \
    ucode -L "$LIB_DIR" -e '
let m = require("config.migration");
printf("%s\n", m.detect_config_migration_source(
    getenv("TACHYON_DETECT_DIR") + "/" + getenv("TACHYON_DETECT_FILE")));
' 2>&1
}

check() {
  local name="$1" want="$2"
  local got
  got="$(detect "$name")"
  [ "$got" = "$want" ] || fail "$name: expected '$want', got '$got'"
}

# --- by name: always legacy --------------------------------------------------
# The point of the fix. forkop is the one that matters: it is indistinguishable
# from Tachyon by content, so only the name can classify it.
check forkop podkop
check podkop podkop
check netshift podkop
check forkop_plus podkop
check podkop_plus podkop

# --- native configs must stay native ----------------------------------------
check tachyon tachyon
check tachyon-native-community tachyon

# --- unknown paths fall back to the content, both ways ----------------------
cp "$WORK_DIR/podkop" "$WORK_DIR/legacy-config.backup"
check legacy-config.backup podkop
cp "$WORK_DIR/tachyon" "$WORK_DIR/some-backup"
check some-backup tachyon

# --- empty and missing files are not a crash --------------------------------
: > "$WORK_DIR/empty-legacy"
cp "$WORK_DIR/empty-legacy" "$WORK_DIR/forkop"
check forkop podkop
rm -f "$WORK_DIR/does-not-exist"
check does-not-exist tachyon

printf 'fault: migration source detection checks passed\n'
