#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SNAPSHOT_UC="$TACHYON_LIB/service/snapshot.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

[ -r "$SNAPSHOT_UC" ] || fail "service/snapshot.uc must own config snapshot logic"
[ -r "$TACHYON_BIN" ] || fail "tachyon entrypoint is missing"

grep -Fq 'snapshot_list: [ "service/snapshot.uc", "snapshot-list", 0 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch snapshot_list to service/snapshot.uc"
grep -Fq 'snapshot_save: [ "service/snapshot.uc", "snapshot-save", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch snapshot_save to service/snapshot.uc"
grep -Fq 'snapshot_restore: [ "service/snapshot.uc", "snapshot-restore", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch snapshot_restore to service/snapshot.uc"
grep -Fq 'snapshot_delete: [ "service/snapshot.uc", "snapshot-delete", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch snapshot_delete to service/snapshot.uc"
grep -Fq 'snapshot_diff: [ "service/snapshot.uc", "snapshot-diff", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch snapshot_diff to service/snapshot.uc"
grep -Fq 'snapshot_export: [ "service/snapshot.uc", "snapshot-export", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch snapshot_export to service/snapshot.uc"
grep -Fq 'snapshot_import: [ "service/snapshot.uc", "snapshot-import", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch snapshot_import to service/snapshot.uc"
grep -Fq 'snapshot_save <name>' "$TACHYON_BIN" ||
  fail "tachyon help must document snapshot_save"

mkdir -p "$WORK_DIR/lib"
mkdir -p "$WORK_DIR/config"
mkdir -p "$WORK_DIR/tachyon"
mkdir -p "$WORK_DIR/snapshots"

printf '%s\n' \
  "config settings 'settings'" \
  "        option dns_type 'udp'" \
  "        option dns '8.8.8.8'" >"$WORK_DIR/config/tachyon"
printf '%s\n' 'snap-data' >"$WORK_DIR/tachyon/data"

cat >"$WORK_DIR/fake-bin" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$TACHYON_SNAPSHOT_BIN_LOG"
exit 0
SH
chmod 0755 "$WORK_DIR/fake-bin"
cat >"$WORK_DIR/fake-validate" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod 0755 "$WORK_DIR/fake-validate"
cat >"$WORK_DIR/fake-validate-fail" <<'SH'
#!/usr/bin/env sh
exit 1
SH
chmod 0755 "$WORK_DIR/fake-validate-fail"

: >"$WORK_DIR/bin.log"

run_uc() {
  local mode="$1"
  shift
  TACHYON_LIB="$WORK_DIR/lib" \
  TACHYON_BIN="$WORK_DIR/fake-bin" \
  TACHYON_CONFIG_NAME="tachyon" \
  TACHYON_CONFIG_PATH="$WORK_DIR/config/tachyon" \
  TACHYON_PERSISTENT_DIR="$WORK_DIR/tachyon" \
  TACHYON_CONFIG_ROOT="$WORK_DIR" \
  TACHYON_SNAPSHOTS_DIR="$WORK_DIR/snapshots" \
  TACHYON_SNAPSHOT_LIMIT="${SNAPSHOT_LIMIT:-10}" \
  TACHYON_SNAPSHOT_VALIDATE_BIN="${VALIDATE_BIN:-$WORK_DIR/fake-validate}" \
  TACHYON_SNAPSHOT_EXPORT_FILE="$WORK_DIR/export-tmp.json" \
  TACHYON_SNAPSHOT_BIN_LOG="$WORK_DIR/bin.log" \
    ucode -L "$WORK_DIR/lib" -L "$TACHYON_LIB" -- "$SNAPSHOT_UC" "$mode" "$@"
}

# ---- snapshot-save: creates a tar.gz with the Telegram backup member layout

run_uc snapshot-save good >"$WORK_DIR/result.json"
grep -Fq '"success": true' "$WORK_DIR/result.json" ||
  fail "snapshot-save must report success"
SAVED_FILE="$(sed -n 's/.*"file": "\([^"]*\)".*/\1/p' "$WORK_DIR/result.json")"
[ -n "$SAVED_FILE" ] || fail "snapshot-save must report the created file"
[[ "$SAVED_FILE" =~ ^[A-Za-z0-9_\-]+-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] ||
  fail "snapshot file name must be <name>-<stamp>.tar.gz: $SAVED_FILE"
[ -f "$WORK_DIR/snapshots/$SAVED_FILE" ] ||
  fail "snapshot archive must exist on disk"
# busybox-based images may lack stat(1); ucode's fs module is always present.
[ "$(ucode -e "let fs = require('fs'); printf('%o', fs.stat('$WORK_DIR/snapshots/$SAVED_FILE').mode & 511);")" = "600" ] ||
  fail "snapshot archive must be chmod 600"
grep -Fxq 'config/tachyon' <(tar -tzf "$WORK_DIR/snapshots/$SAVED_FILE") ||
  fail "snapshot must contain config/tachyon member"
grep -Fxq 'tachyon/data' <(tar -tzf "$WORK_DIR/snapshots/$SAVED_FILE") ||
  fail "snapshot must contain tachyon/data member"

# ---- snapshot-save with a second snapshot and list ordering

run_uc snapshot-save good >/dev/null
run_uc snapshot-list >"$WORK_DIR/result.json"
grep -Fq '"success": true' "$WORK_DIR/result.json" ||
  fail "snapshot-list must report success"
grep -Fq '"size": ' "$WORK_DIR/result.json" ||
  fail "snapshot-list must include the archive size"
grep -Fq 'good-' "$WORK_DIR/result.json" ||
  fail "snapshot-list must include saved snapshot names"

# ---- rotation: only SNAPSHOT_LIMIT archives are kept

SNAPSHOT_LIMIT=2 run_uc snapshot-save a >/dev/null
sleep 1
SNAPSHOT_LIMIT=2 run_uc snapshot-save b >/dev/null
sleep 1
SNAPSHOT_LIMIT=2 run_uc snapshot-save c >/dev/null
run_uc snapshot-list >"$WORK_DIR/result.json"
grep -Fq 'c-' "$WORK_DIR/result.json" || fail "rotation must keep the newest snapshot"
grep -Fq 'b-' "$WORK_DIR/result.json" || fail "rotation must keep the second newest snapshot"
if grep -Fq 'a-' "$WORK_DIR/result.json"; then
  fail "rotation must remove the oldest snapshot"
fi

# ---- snapshot-restore: replaces config and data, chmod 600, restarts the service

run_uc snapshot-save good >"$WORK_DIR/result.json"
SAVED_FILE="$(sed -n 's/.*"file": "\([^"]*\)".*/\1/p' "$WORK_DIR/result.json")"
printf '%s\n' \
  "config settings 'settings'" \
  "        option dns_type 'udp'" \
  "        option dns '1.1.1.1'" >"$WORK_DIR/config/tachyon"
printf '%s\n' 'changed-data' >"$WORK_DIR/tachyon/data"
run_uc snapshot-restore "$SAVED_FILE" >"$WORK_DIR/result.json"
grep -Fq '"success": true' "$WORK_DIR/result.json" ||
  fail "snapshot-restore must report success"
for _ in $(seq 1 30); do
  grep -Fxq 'restart' "$WORK_DIR/bin.log" 2>/dev/null && break
  sleep 1
done
grep -Fxq 'restart' "$WORK_DIR/bin.log" ||
  fail "snapshot-restore must restart the service through the backend entrypoint"
grep -Fq "option dns '8.8.8.8'" "$WORK_DIR/config/tachyon" ||
  fail "snapshot-restore must replace the config with the snapshot content"
[ "$(ucode -e "let fs = require('fs'); printf('%o', fs.stat('$WORK_DIR/config/tachyon').mode & 511);")" = "600" ] ||
  fail "restored config must be chmod 600"
[ "$(cat "$WORK_DIR/tachyon/data")" = 'snap-data' ] ||
  fail "snapshot-restore must restore the persistent data"

# ---- restore rollback when validation fails

printf '%s\n' \
  "config settings 'settings'" \
  "        option dns_type 'udp'" \
  "        option dns '9.9.9.9'" >"$WORK_DIR/config/tachyon"
VALIDATE_BIN="$WORK_DIR/fake-validate-fail" run_uc snapshot-restore "$SAVED_FILE" >"$WORK_DIR/result.json" &&
  fail "snapshot-restore must fail when validation fails"
grep -Fq '"success": false' "$WORK_DIR/result.json" ||
  fail "failed restore must report failure"
grep -Fq 'rolled back' "$WORK_DIR/result.json" ||
  fail "failed restore must report the rollback"
grep -Fq "option dns '9.9.9.9'" "$WORK_DIR/config/tachyon" ||
  fail "failed restore must keep the current config untouched"
[ "$(cat "$WORK_DIR/tachyon/data")" = 'snap-data' ] ||
  fail "failed restore must not touch the persistent data"

# ---- unsafe archives are rejected

mkdir -p "$WORK_DIR/evil"
printf '%s\n' 'x' >"$WORK_DIR/evil/x"
tar -czf "$WORK_DIR/snapshots/evil-20240101-010101.tar.gz" -C "$WORK_DIR" evil/x
run_uc snapshot-restore "evil-20240101-010101.tar.gz" >"$WORK_DIR/result.json" &&
  fail "snapshot-restore must reject archives with unexpected members"
grep -Fq '"success": false' "$WORK_DIR/result.json" || fail "unsafe archive must fail"
grep -Fq 'unsafe archive' "$WORK_DIR/result.json" ||
  fail "unsafe archive failure must name the reason"

# ---- data-only snapshots restore data without touching the config

mv "$WORK_DIR/tachyon" "$WORK_DIR/tachyon.hold"
mkdir -p "$WORK_DIR/tachyon"
printf '%s\n' 'only-data' >"$WORK_DIR/tachyon/only"
tar -czf "$WORK_DIR/snapshots/only-20240101-010101.tar.gz" -C "$WORK_DIR" tachyon
rm -rf "$WORK_DIR/tachyon"
mv "$WORK_DIR/tachyon.hold" "$WORK_DIR/tachyon"
run_uc snapshot-restore "only-20240101-010101.tar.gz" >"$WORK_DIR/result.json"
grep -Fq '"success": true' "$WORK_DIR/result.json" ||
  fail "data-only snapshot restore must report success"
[ "$(cat "$WORK_DIR/tachyon/only")" = 'only-data' ] ||
  fail "data-only snapshot must restore the persistent data"
grep -Fq "option dns '9.9.9.9'" "$WORK_DIR/config/tachyon" ||
  fail "data-only snapshot must not touch the config"

# ---- snapshot-delete

run_uc snapshot-delete "only-20240101-010101.tar.gz" >"$WORK_DIR/result.json"
grep -Fq '"success": true' "$WORK_DIR/result.json" ||
  fail "snapshot-delete must report success"
[ ! -e "$WORK_DIR/snapshots/only-20240101-010101.tar.gz" ] ||
  fail "snapshot-delete must remove the archive"
run_uc snapshot-delete "only-20240101-010101.tar.gz" >"$WORK_DIR/result.json" &&
  fail "snapshot-delete must fail for a missing snapshot"
grep -Fq 'snapshot not found' "$WORK_DIR/result.json" ||
  fail "missing snapshot delete must say snapshot not found"
run_uc snapshot-delete "evil" >"$WORK_DIR/result.json" &&
  fail "snapshot-delete must reject invalid file names"
grep -Fq 'invalid snapshot name' "$WORK_DIR/result.json" ||
  fail "invalid file name delete must be rejected"

# ---- argument validation

run_uc snapshot-save >"$WORK_DIR/result.json" && fail "snapshot-save without a name must fail"
grep -Fq 'snapshot name required' "$WORK_DIR/result.json" ||
  fail "snapshot-save without a name must explain itself"
run_uc snapshot-save "./" >"$WORK_DIR/result.json" && fail "unsafe name must be rejected"
grep -Fq 'invalid snapshot name' "$WORK_DIR/result.json" ||
  fail "unsafe name must be rejected as invalid"
run_uc snapshot-restore "evil" >"$WORK_DIR/result.json" && fail "restore must reject invalid files"
grep -Fq 'invalid snapshot name' "$WORK_DIR/result.json" ||
  fail "restore of an invalid file name must be rejected"

# ---- snapshot-diff (with secret masking), snapshot-export, and snapshot-import

printf '%s\n' \
  "config settings 'settings'" \
  "        option dns_type 'udp'" \
  "        option dns '8.8.8.8'" \
  "        option bot_token 'super-secret-token-1'" >"$WORK_DIR/config/tachyon"
run_uc snapshot-save prof1 >"$WORK_DIR/result.json"
PROF_FILE="$(sed -n 's/.*"file": "\([^"]*\)".*/\1/p' "$WORK_DIR/result.json")"

printf '%s\n' \
  "config settings 'settings'" \
  "        option dns_type 'doh'" \
  "        option dns '1.1.1.1'" \
  "        option bot_token 'super-secret-token-2'" >"$WORK_DIR/config/tachyon"

run_uc snapshot-diff "$PROF_FILE" >"$WORK_DIR/diff.json"
grep -Fq '"success": true' "$WORK_DIR/diff.json" ||
  fail "snapshot-diff must succeed"
grep -Fq '"has_changes": true' "$WORK_DIR/diff.json" ||
  fail "snapshot-diff must detect changes"
if grep -Fq 'super-secret-token' "$WORK_DIR/diff.json"; then
  fail "snapshot-diff must mask sensitive UCI options like bot_token"
fi

run_uc snapshot-export "$PROF_FILE" >"$WORK_DIR/export.json"
grep -Fq '"format": "tachyon-profile-v1"' "$WORK_DIR/export.json" ||
  fail "snapshot-export must emit tachyon-profile-v1 format"
[ -f "$WORK_DIR/export-tmp.json" ] ||
  fail "snapshot-export must also write fallback JSON to TACHYON_SNAPSHOT_EXPORT_FILE"
grep -Fq '"format": "tachyon-profile-v1"' "$WORK_DIR/export-tmp.json" ||
  fail "fallback export file must contain tachyon-profile-v1 JSON"

run_uc snapshot-delete "$PROF_FILE" >/dev/null
run_uc snapshot-import "$WORK_DIR/export.json" >"$WORK_DIR/import.json"
grep -Fq '"success": true' "$WORK_DIR/import.json" ||
  fail "snapshot-import must succeed on exported profile JSON"
IMPORTED_FILE="$(sed -n 's/.*"file": "\([^"]*\)".*/\1/p' "$WORK_DIR/import.json")"
[ -f "$WORK_DIR/snapshots/$IMPORTED_FILE" ] ||
  fail "snapshot-import must create the archive in snapshots directory"

# ---- heavy cache directories (rulesets, installer-backups, subscription-cache,
# component-backups, hosts-lists) must be excluded from snapshot-save, preserved
# on snapshot-restore, and stripped during snapshot-export of legacy bloated archives.

mkdir -p "$WORK_DIR/tachyon/rulesets" "$WORK_DIR/tachyon/installer-backups" "$WORK_DIR/tachyon/subscription-cache" "$WORK_DIR/tachyon/component-backups" "$WORK_DIR/tachyon/hosts-lists"
printf '%s\n' 'compiled-srs-blob' >"$WORK_DIR/tachyon/rulesets/heavy.srs"
printf '%s\n' 'old-ipk' >"$WORK_DIR/tachyon/installer-backups/old.ipk"
printf '%s\n' 'sub-cache' >"$WORK_DIR/tachyon/subscription-cache/sub.json"
printf '%s\n' 'heavy-binary-backup' >"$WORK_DIR/tachyon/component-backups/tachyon-core.bin"
printf '%s\n' 'hosts-list-cache' >"$WORK_DIR/tachyon/hosts-lists/adblock.txt"
printf '%s\n' 'user-custom-list' >"$WORK_DIR/tachyon/custom.lst"

run_uc snapshot-save slim >"$WORK_DIR/result.json"
SLIM_FILE="$(sed -n 's/.*"file": "\([^"]*\)".*/\1/p' "$WORK_DIR/result.json")"
if tar -tzf "$WORK_DIR/snapshots/$SLIM_FILE" | grep -Eq '^tachyon/(rulesets|installer-backups|subscription-cache|component-backups|hosts-lists)(/|$)'; then
  fail "snapshot-save must exclude rulesets, installer-backups, subscription-cache, component-backups, and hosts-lists"
fi
grep -Fxq 'tachyon/custom.lst' <(tar -tzf "$WORK_DIR/snapshots/$SLIM_FILE") ||
  fail "snapshot-save must preserve user files in /etc/tachyon"

printf '%s\n' 'updated-srs-blob' >"$WORK_DIR/tachyon/rulesets/heavy.srs"
printf '%s\n' 'updated-binary-backup' >"$WORK_DIR/tachyon/component-backups/tachyon-core.bin"
rm -f "$WORK_DIR/tachyon/custom.lst"
run_uc snapshot-restore "$SLIM_FILE" >"$WORK_DIR/result.json"
grep -Fq '"success": true' "$WORK_DIR/result.json" ||
  fail "snapshot-restore of slim archive must succeed"
[ "$(cat "$WORK_DIR/tachyon/custom.lst")" = 'user-custom-list' ] ||
  fail "snapshot-restore must restore user files"
[ "$(cat "$WORK_DIR/tachyon/rulesets/heavy.srs")" = 'updated-srs-blob' ] ||
  fail "snapshot-restore must preserve existing rulesets directory on disk"
[ "$(cat "$WORK_DIR/tachyon/component-backups/tachyon-core.bin")" = 'updated-binary-backup' ] ||
  fail "snapshot-restore must preserve existing component-backups directory on disk"

# Create a legacy bloated archive that still contains rulesets/ and component-backups/ inside it
tar -czf "$WORK_DIR/snapshots/legacy-20250101-010101.tar.gz" -C "$WORK_DIR" config/tachyon tachyon
grep -Fxq 'tachyon/rulesets/heavy.srs' <(tar -tzf "$WORK_DIR/snapshots/legacy-20250101-010101.tar.gz") ||
  fail "legacy test archive must contain rulesets/heavy.srs"
grep -Fxq 'tachyon/component-backups/tachyon-core.bin' <(tar -tzf "$WORK_DIR/snapshots/legacy-20250101-010101.tar.gz") ||
  fail "legacy test archive must contain component-backups/tachyon-core.bin"

run_uc snapshot-export "legacy-20250101-010101.tar.gz" >"$WORK_DIR/legacy-export.json"
grep -Fq '"success": true' "$WORK_DIR/legacy-export.json" ||
  fail "snapshot-export of legacy archive must succeed"
run_uc snapshot-import "$WORK_DIR/legacy-export.json" >"$WORK_DIR/legacy-import.json"
LEGACY_IMPORTED="$(sed -n 's/.*"file": "\([^"]*\)".*/\1/p' "$WORK_DIR/legacy-import.json")"
if tar -tzf "$WORK_DIR/snapshots/$LEGACY_IMPORTED" | grep -Eq '^tachyon/(rulesets|installer-backups|subscription-cache|component-backups|hosts-lists)(/|$)'; then
  fail "snapshot-export must strip heavy cache directories from legacy archives"
fi

# ---- BusyBox tar -tzf lists top-level directory as "tachyon" (without trailing slash)
mkdir -p "$WORK_DIR/fakebin"
cat >"$WORK_DIR/fakebin/tar" <<'EOF'
#!/bin/sh
if [ "$1" = "-tzf" ]; then
  /bin/tar "$@" | sed 's|^tachyon/$|tachyon|; s|^config/$|config|'
else
  exec /bin/tar "$@"
fi
EOF
chmod +x "$WORK_DIR/fakebin/tar"
PATH="$WORK_DIR/fakebin:$PATH" run_uc snapshot-export "$SLIM_FILE" >"$WORK_DIR/bb-export.json"
grep -Fq '"success": true' "$WORK_DIR/bb-export.json" ||
  fail "snapshot-export must accept BusyBox tar -tzf output where directory member is 'tachyon' without trailing slash"
PATH="$WORK_DIR/fakebin:$PATH" run_uc snapshot-import "$WORK_DIR/bb-export.json" >"$WORK_DIR/bb-import.json"
grep -Fq '"success": true' "$WORK_DIR/bb-import.json" ||
  fail "snapshot-import must accept BusyBox tar -tzf output where directory member is 'tachyon' without trailing slash"

# ---- Chunked snapshot export (read-chunk) and chunked snapshot import (chunk-init / chunk-append)
run_uc snapshot-export "read-chunk:0:128" >"$WORK_DIR/chunk-read.json"
grep -Fq '"success": true' "$WORK_DIR/chunk-read.json" ||
  fail "snapshot-export read-chunk must succeed"
grep -Fq '"chunk":' "$WORK_DIR/chunk-read.json" ||
  fail "snapshot-export read-chunk must include chunk string"

run_uc snapshot-import "chunk-init" >"$WORK_DIR/chunk-init.json"
grep -Fq '"success": true' "$WORK_DIR/chunk-init.json" ||
  fail "snapshot-import chunk-init must succeed"
B64_PAYLOAD="$(ucode -e "let fs = require('fs'); print(b64enc(fs.readfile('$WORK_DIR/export-tmp.json')));")"
HALF_LEN=$(( ${#B64_PAYLOAD} / 2 ))
# Ensure first chunk length is a multiple of 4 for base64 decoding
HALF_LEN=$(( (HALF_LEN / 4) * 4 ))
CHUNK1="${B64_PAYLOAD:0:$HALF_LEN}"
CHUNK2="${B64_PAYLOAD:$HALF_LEN}"
run_uc snapshot-import "chunk-append:$CHUNK1" >"$WORK_DIR/chunk-app1.json"
grep -Fq '"success": true' "$WORK_DIR/chunk-app1.json" ||
  fail "snapshot-import chunk-append first chunk must succeed"
run_uc snapshot-import "chunk-append:$CHUNK2" >"$WORK_DIR/chunk-app2.json"
grep -Fq '"success": true' "$WORK_DIR/chunk-app2.json" ||
  fail "snapshot-import chunk-append second chunk must succeed"
run_uc snapshot-import "/tmp/tachyon-snapshot-import.json" >"$WORK_DIR/chunk-finish.json"
grep -Fq '"success": true' "$WORK_DIR/chunk-finish.json" ||
  fail "snapshot-import from assembled chunk file must succeed"

ACL_FILE="$ROOT_DIR/tachyon/files/usr/share/rpcd/acl.d/luci-app-tachyon.json"
grep -Fq '"cgi-io"' "$ACL_FILE" ||
  fail "luci-app-tachyon ACL must grant cgi-io permissions for LuCI fs.read/fs.write"

# ---- Compact transfer codes (tachyon://t1/... short encrypted token & tachyon://cfg1/... offline fallback)
cat >"$WORK_DIR/config/tachyon" <<'EOF'
config settings 'settings'
	option dns_type 'doh'
	option dns '1.1.1.1'
	option engine 'tachyon-core'

config section 's_media'
	option label 'Media'
	option enabled '1'

config server 'srv_eu'
	option label 'EU Inbound VPN'
	option protocol 'vless'

config outbound_source 'sub_main'
	option label 'Main Sub'
	list proxy_links 'vless://00000000-0000-0000-0000-000000000001@198.51.100.10:443#Node1'
EOF
printf '%s\n' 'transfer-custom-domain.example' >"$WORK_DIR/tachyon/custom.lst"

TACHYON_TRANSFER_RELAY_DIR="$WORK_DIR/relay" run_uc snapshot-export "code:routes" >"$WORK_DIR/code-routes.json"
grep -Fq '"success": true' "$WORK_DIR/code-routes.json" ||
  fail "snapshot-export code:routes must succeed"
grep -Fq '"scope": "routes"' "$WORK_DIR/code-routes.json" ||
  fail "snapshot-export code:routes must report scope=routes"
ROUTES_CODE="$(sed -n 's/.*"code": "\([^"]*\)".*/\1/p' "$WORK_DIR/code-routes.json")"
case "$ROUTES_CODE" in
  tachyon://t1/l/*) ;;
  *) fail "snapshot-export code:routes with relay must produce a short tachyon://t1/ token (got: $ROUTES_CODE)" ;;
esac

TACHYON_TRANSFER_OFFLINE_ONLY=1 run_uc snapshot-export "code:full" >"$WORK_DIR/code-full.json"
grep -Fq '"success": true' "$WORK_DIR/code-full.json" ||
  fail "snapshot-export code:full must succeed"
FULL_CODE="$(sed -n 's/.*"code": "\([^"]*\)".*/\1/p' "$WORK_DIR/code-full.json")"
case "$FULL_CODE" in
  tachyon://cfg1/*|tachyon://cfg1u/*) ;;
  *) fail "snapshot-export with TACHYON_TRANSFER_OFFLINE_ONLY=1 must produce a tachyon://cfg1/ code" ;;
esac

TACHYON_TRANSFER_RELAY_DIR="$WORK_DIR/relay" run_uc snapshot-import "code-inspect:$ROUTES_CODE" >"$WORK_DIR/code-inspect.json"
grep -Fq '"success": true' "$WORK_DIR/code-inspect.json" ||
  fail "snapshot-import code-inspect must succeed"
grep -Fq '"scope": "routes"' "$WORK_DIR/code-inspect.json" ||
  fail "code-inspect must report scope=routes"
grep -Fq '"Media"' "$WORK_DIR/code-inspect.json" ||
  fail "code-inspect must include section label Media"

# Target router has different system settings and its own existing route section
cat >"$WORK_DIR/config/tachyon" <<'EOF'
config settings 'settings'
	option dns_type 'udp'
	option dns '9.9.9.9'
	option engine 'sing-box'

config section 's_existing'
	option label 'Existing Local Route'
	option enabled '1'
EOF
rm -f "$WORK_DIR/tachyon/custom.lst"

# 1) Merge mode: keeps s_existing and target settings, adds s_media and sub_main, and restores custom.lst
TACHYON_TRANSFER_RELAY_DIR="$WORK_DIR/relay" run_uc snapshot-import "code-apply:merge:$ROUTES_CODE" >"$WORK_DIR/code-merge.json"
grep -Fq '"success": true' "$WORK_DIR/code-merge.json" ||
  fail "code-apply:merge must succeed"
grep -Fq "option dns '9.9.9.9'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:merge (routes) must preserve target router settings"
grep -Fq "config section 's_existing'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:merge must preserve existing route sections on target router"
grep -Fq "config section 's_media'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:merge must add incoming route sections"
grep -Fq "config outbound_source 'sub_main'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:merge must add incoming outbound_source sections"
[ "$(cat "$WORK_DIR/tachyon/custom.lst")" = 'transfer-custom-domain.example' ] ||
  fail "code-apply:merge must transfer user files in /etc/tachyon"

# 2) Replace mode (scope=routes): preserves target settings, replaces s_existing with s_media
TACHYON_TRANSFER_RELAY_DIR="$WORK_DIR/relay" run_uc snapshot-import "code-apply:replace:$ROUTES_CODE" >"$WORK_DIR/code-replace.json"
grep -Fq '"success": true' "$WORK_DIR/code-replace.json" ||
  fail "code-apply:replace must succeed"
grep -Fq "option dns '9.9.9.9'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:replace (routes) must preserve target router settings"
if grep -Fq "config section 's_existing'" "$WORK_DIR/config/tachyon"; then
  fail "code-apply:replace must remove old route sections not in the transfer code"
fi
grep -Fq "config section 's_media'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:replace must write transferred route sections"

# 3) Replace mode (scope=full): replaces target settings and includes inbound server
run_uc snapshot-import "code-apply:replace:$FULL_CODE" >"$WORK_DIR/code-replace-full.json"
grep -Fq '"success": true' "$WORK_DIR/code-replace-full.json" ||
  fail "code-apply:replace (full) must succeed"
grep -Fq "option dns '1.1.1.1'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:replace (full) must apply transferred settings"
grep -Fq "config server 'srv_eu'" "$WORK_DIR/config/tachyon" ||
  fail "code-apply:replace (full) must include inbound VPN server sections"

# 4) Negative test: corrupted transfer code or wrong token key is rejected without modifying config
run_uc snapshot-import "code-apply:replace:tachyon://cfg1/not_valid_gzip_payload" >"$WORK_DIR/code-bad.json" &&
  fail "corrupted transfer code must fail"
grep -Fq '"success": false' "$WORK_DIR/code-bad.json" ||
  fail "corrupted transfer code must report success=false"
grep -Fq "option dns '1.1.1.1'" "$WORK_DIR/config/tachyon" ||
  fail "rejected transfer code must leave current config intact"

printf 'snapshot contract checks passed\n'
