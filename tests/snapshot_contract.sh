#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
SNAPSHOT_UC="$TACHYON_LIB/service/snapshot.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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
  TACHYON_SNAPSHOT_BIN_LOG="$WORK_DIR/bin.log" \
    ucode -L "$WORK_DIR/lib" -L "$TACHYON_LIB" "$SNAPSHOT_UC" "$mode" "$@"
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

printf 'snapshot contract checks passed\n'
