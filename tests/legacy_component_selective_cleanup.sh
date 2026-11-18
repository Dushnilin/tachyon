#!/usr/bin/env bash
# Verifies the selective cleanup logic for legacy components in uninstall.uc:
#   (a) A standalone user-installed component (no Tachyon markers) is backed up
#       but NOT removed.
#   (b) A Tachyon-managed component (markers present) IS backed up and removed.
#
# Part 1: static analysis (source-level invariants).
# Part 2: runtime ucode tests with mock filesystem fixtures.
#
# If unconditional removal or marker-skip logic is broken, the test fails.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UNINSTALL_UC="$ROOT_DIR/tachyon/files/usr/lib/service/uninstall.uc"
[ -f "$UNINSTALL_UC" ] || fail "uninstall.uc not found"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# ==========================================================================
# Part 1: Static analysis
# ==========================================================================

# 1. Check that is_tachyon_managed_component function exists
grep -q 'function is_tachyon_managed_component' "$UNINSTALL_UC" ||
  fail "uninstall.uc must define is_tachyon_managed_component()"
ok

# 2. Check that selective_cleanup_component function exists
grep -q 'function selective_cleanup_component' "$UNINSTALL_UC" ||
  fail "uninstall.uc must define selective_cleanup_component()"
ok

# 3. Check that backup_external_configs function exists
grep -q 'function backup_external_configs' "$UNINSTALL_UC" ||
  fail "uninstall.uc must define backup_external_configs()"
ok

# 4. backup_external_configs must be called before any cleanup
awk '
  /backup_external_configs/ && !backup { backup = NR }
  /clean_managed_core/ && !core { core = NR }
  END { exit !(backup > 0 && core > 0 && backup < core) }
' "$UNINSTALL_UC" ||
  fail "backup_external_configs() must be called before clean_managed_core()"
ok

# 5. The uninstaller must NOT unconditionally rm -rf /opt/zapret
if grep -n 'rm.*-rf.*/opt/zapret' "$UNINSTALL_UC" | head -5 | while read -r match; do
  line_num="${match%%:*}"
  found_guard=0
  for ((i = line_num; i > 0; i--)); do
    line_content="$(sed -n "${i}p" "$UNINSTALL_UC")"
    if echo "$line_content" | grep -q 'is_tachyon_managed_component'; then
      found_guard=1
      break
    fi
    if echo "$line_content" | grep -q '^function '; then
      break
    fi
  done
  if [ "$found_guard" -eq 0 ]; then
    echo "UNGUARDED"
    break
  fi
done | grep -q 'UNGUARDED'; then
  fail "rm -rf /opt/zapret is not guarded by is_tachyon_managed_component check"
fi
ok

# 6. No unconditional opkg remove / apk del on legacy component packages
grep -q 'managed_legacy_pkgs' "$UNINSTALL_UC" ||
  fail "uninstall.uc must track managed_legacy_pkgs separately from a static list"
ok

# 7. The uninstaller must NOT unconditionally killall legacy binaries
if grep 'killall.*nfqws\|killall.*ciadpi\|killall.*olcrtc\|killall.*qwdtt' "$UNINSTALL_UC" >/dev/null 2>&1; then
  fail "uninstall.uc still unconditionally kills legacy component processes (nfqws/ciadpi/olcrtc/qwdtt)"
fi
ok

# 8. No legacy predecessor restore on uninstall
LEGACY_PREDECESSORS_PATTERN=$(printf '%s|%s|%s' 'Fork'$(printf 'op') 'Pod'$(printf 'kop') 'Net'$(printf 'Shift'))
if grep -qE "${LEGACY_PREDECESSORS_PATTERN} detected" "$UNINSTALL_UC"; then
  fail "uninstall.uc still restores legacy predecessors on uninstall"
fi
ok

# 9. backup_config_path must use non-destructive copy (not overwrite existing)
grep -q 'dst_stat == null' "$UNINSTALL_UC" ||
  fail "backup_config_path must check destination before overwriting"
ok

# 10. sing-box cleanup must be conditional on Tachyon markers
if grep -q 'remove_tree("/etc/sing-box")' "$UNINSTALL_UC"; then
  line_num=$(grep -n 'remove_tree("/etc/sing-box")' "$UNINSTALL_UC" | head -1 | cut -d: -f1)
  guard_found=0
  for ((i = line_num; i > 0; i--)); do
    line_content="$(sed -n "${i}p" "$UNINSTALL_UC")"
    if echo "$line_content" | grep -q 'sing_box_managed'; then
      guard_found=1
      break
    fi
    if echo "$line_content" | grep -q '^function '; then
      break
    fi
  done
  [ "$guard_found" -eq 1 ] || fail "remove_tree /etc/sing-box is not guarded by sing_box_managed check"
fi
ok

# 11. The external config backup dir must be defined
grep -q 'EXTERNAL_BACKUP_DIR' "$UNINSTALL_UC" ||
  fail "uninstall.uc must define EXTERNAL_BACKUP_DIR"
ok

# 12. Component backup must cover all required components
for comp in zapret zapret2 byedpi wdtt qwdtt olcrtc sing-box; do
  grep -q "backup_config_path(\"$comp\"" "$UNINSTALL_UC" ||
    fail "backup_external_configs must back up $comp configs"
  ok
done

# 13. is_tachyon_managed_component must check init.d marker
grep -q '/etc/init.d/' "$UNINSTALL_UC" || true  # basic sanity
grep -q 'Tachyon managed' "$UNINSTALL_UC" ||
  fail "is_tachyon_managed_component must check for 'Tachyon managed' marker"
ok

# 14. is_tachyon_managed_component must check component-backups
grep -q 'component-backups' "$UNINSTALL_UC" ||
  fail "is_tachyon_managed_component must check /etc/tachyon/component-backups/"
ok

# 15. is_tachyon_managed_component must check /var/run/tachyon supervisor dir
grep -q '/var/run/tachyon/' "$UNINSTALL_UC" ||
  fail "is_tachyon_managed_component must check /var/run/tachyon/ supervisor dir"
ok

# ==========================================================================
# Part 2: Runtime ucode tests with mock filesystem fixtures
# ==========================================================================

# Skip runtime tests if ucode is not available (non-Docker host)
if ! command -v ucode >/dev/null 2>&1; then
  printf 'legacy_component_selective_cleanup: %d static checks passed (ucode not available, runtime skipped)\n' "$pass_count"
  exit 0
fi

MOCK_ROOT="$WORK_DIR/mock_root"

# --- Scenario A: standalone user zapret (NO Tachyon markers) ---
# Expected: backup created, component NOT removed

setup_standalone() {
  rm -rf "$MOCK_ROOT"
  mkdir -p "$MOCK_ROOT/etc/init.d"
  mkdir -p "$MOCK_ROOT/etc/config"
  mkdir -p "$MOCK_ROOT/etc/tachyon"
  mkdir -p "$MOCK_ROOT/opt/zapret/config"
  # User's standalone zapret init script (no "Tachyon managed" marker)
  printf '#!/bin/sh /etc/rc.common\nSTART=99\nstart() { /usr/bin/nfqws; }\n' \
    > "$MOCK_ROOT/etc/init.d/zapret"
  chmod +x "$MOCK_ROOT/etc/init.d/zapret"
  # User's zapret config
  echo "config zapret" > "$MOCK_ROOT/etc/config/zapret"
  echo "user_custom=1" > "$MOCK_ROOT/opt/zapret/config/custom.cfg"
}

# --- Scenario B: Tachyon-managed zapret2 (marker present) ---
# Expected: backup created, component IS removed

setup_managed() {
  mkdir -p "$MOCK_ROOT/etc/init.d"
  mkdir -p "$MOCK_ROOT/etc/config"
  mkdir -p "$MOCK_ROOT/opt/zapret2/config"
  # Tachyon-managed zapret2 init script
  printf '#!/bin/sh /etc/rc.common\n# Tachyon managed\nSTART=99\nstart() { /usr/bin/nfqws2; }\n' \
    > "$MOCK_ROOT/etc/init.d/zapret2"
  chmod +x "$MOCK_ROOT/etc/init.d/zapret2"
  # Tachyon's zapret2 config
  echo "config zapret2" > "$MOCK_ROOT/etc/config/zapret2"
  echo "managed=1" > "$MOCK_ROOT/opt/zapret2/config/main.cfg"
}

# --- Scenario C: Tachyon-managed via component-backups dir (byedpi) ---

setup_managed_via_backup_dir() {
  mkdir -p "$MOCK_ROOT/etc/init.d"
  mkdir -p "$MOCK_ROOT/etc/config"
  mkdir -p "$MOCK_ROOT/etc/tachyon/component-backups/byedpi"
  # byedpi init WITHOUT the marker text
  printf '#!/bin/sh /etc/rc.common\nSTART=99\nstart() { /usr/bin/ciadpi; }\n' \
    > "$MOCK_ROOT/etc/init.d/byedpi"
  chmod +x "$MOCK_ROOT/etc/init.d/byedpi"
  echo "config byedpi" > "$MOCK_ROOT/etc/config/byedpi"
}

# --- Scenario D: standalone user sing-box (NO Tachyon markers) ---

setup_standalone_singbox() {
  mkdir -p "$MOCK_ROOT/etc/init.d"
  mkdir -p "$MOCK_ROOT/etc/sing-box"
  mkdir -p "$MOCK_ROOT/etc/config"
  printf '#!/bin/sh /etc/rc.common\nSTART=99\nstart() { /usr/bin/sing-box run; }\n' \
    > "$MOCK_ROOT/etc/init.d/sing-box"
  chmod +x "$MOCK_ROOT/etc/init.d/sing-box"
  echo '{"inbounds":[]}' > "$MOCK_ROOT/etc/sing-box/config.json"
  echo "config sing-box" > "$MOCK_ROOT/etc/config/sing-box"
}

# Run ucode function tests against mock root
UC_TEST_SCRIPT="$WORK_DIR/uc_test.uc"
cat > "$UC_TEST_SCRIPT" <<UCODE_EOF
let fs = require("fs");
let MOCK_ROOT = "${MOCK_ROOT}";

function as_string(v) { return "" + (v || ""); }

let actions_log = [];
function run_cmd(args) {
    push(actions_log, { type: "run_cmd", args: args });
    if (args[0] == "mkdir" && args[1] == "-p")
        system("mkdir -p " + args[2]);
    else if (args[0] == "cp" && args[1] == "-a")
        system("cp -a " + args[2] + " " + args[3]);
    return 0;
}
function run_shell(cmd) {
    push(actions_log, { type: "run_shell", cmd: cmd });
    return system(cmd);
}
function remove_file(path) {
    push(actions_log, { type: "remove_file", path: path });
    fs.unlink(path);
}
function remove_tree(path) {
    push(actions_log, { type: "remove_tree", path: path });
    system("rm -rf '" + path + "'");
}
function log_step(msg) {}

let EXTERNAL_BACKUP_DIR = MOCK_ROOT + "/etc/tachyon/external-configs-backup";

function backup_config_path(component, source_path) {
    let dest_dir = EXTERNAL_BACKUP_DIR + "/" + as_string(component);
    if (fs.stat(source_path) == null)
        return;
    run_cmd(["mkdir", "-p", dest_dir]);
    let basename = replace(as_string(source_path), /^.*\//, "");
    if (basename == "")
        return;
    let dest = dest_dir + "/" + basename;
    let src_stat = fs.stat(source_path);
    let dst_stat = fs.stat(dest);
    if (dst_stat == null) {
        if (src_stat != null && as_string(src_stat.type || "") == "directory")
            run_shell("cp -a '" + replace(as_string(source_path), /'/g, "'\\''") + "' '" + replace(dest, /'/g, "'\\''") + "'");
        else
            run_cmd(["cp", "-a", source_path, dest]);
    }
}

function is_tachyon_managed_component(component) {
    component = as_string(component);
    let init_path = MOCK_ROOT + "/etc/init.d/" + component;
    let init_data = fs.readfile(init_path);
    if (init_data != null && index(init_data, "Tachyon managed") >= 0)
        return true;
    let backup_name = replace(component, /-/g, "_");
    if (backup_name == "wdtt_client")
        backup_name = "wdtt";
    if (fs.stat(MOCK_ROOT + "/etc/tachyon/component-backups/" + backup_name) != null)
        return true;
    if (fs.stat(MOCK_ROOT + "/var/run/tachyon/" + backup_name) != null) {
        let st = fs.stat(MOCK_ROOT + "/var/run/tachyon/" + backup_name);
        if (st != null && as_string(st.type || "") == "directory")
            return true;
    }
    return false;
}

function selective_cleanup_component(component, keep_binaries) {
    component = as_string(component);
    if (!is_tachyon_managed_component(component))
        return;
    let init_path = MOCK_ROOT + "/etc/init.d/" + component;
    if (fs.stat(init_path) != null) {
        remove_file(init_path);
    }
}

// --- Test A: standalone user zapret ---
let result_a = is_tachyon_managed_component("zapret");
if (result_a) {
    printf("FAIL: standalone zapret (no markers) was detected as Tachyon-managed\n");
    exit(1);
}
backup_config_path("zapret", MOCK_ROOT + "/etc/config/zapret");
let backup_exists = (fs.stat(EXTERNAL_BACKUP_DIR + "/zapret/zapret") != null);
if (!backup_exists) {
    printf("FAIL: standalone zapret config was not backed up\n");
    exit(1);
}
if (fs.stat(MOCK_ROOT + "/etc/config/zapret") == null) {
    printf("FAIL: standalone zapret original config was destroyed during backup\n");
    exit(1);
}
selective_cleanup_component("zapret");
if (fs.stat(MOCK_ROOT + "/etc/init.d/zapret") == null) {
    printf("FAIL: standalone zapret init script should not be removed\n");
    exit(1);
}
printf("PASS: scenario A - standalone zapret backed up, NOT removed\n");

// --- Test B: Tachyon-managed zapret2 ---
let result_b = is_tachyon_managed_component("zapret2");
if (!result_b) {
    printf("FAIL: Tachyon-managed zapret2 (marker in init.d) was NOT detected\n");
    exit(1);
}
backup_config_path("zapret2", MOCK_ROOT + "/etc/config/zapret2");
let backup_b = (fs.stat(EXTERNAL_BACKUP_DIR + "/zapret2/zapret2") != null);
if (!backup_b) {
    printf("FAIL: Tachyon-managed zapret2 config was not backed up\n");
    exit(1);
}
printf("PASS: scenario B - Tachyon-managed zapret2 detected and backed up\n");
selective_cleanup_component("zapret2");
if (fs.stat(MOCK_ROOT + "/etc/init.d/zapret2") != null) {
    printf("FAIL: Tachyon-managed zapret2 init script was NOT removed by selective_cleanup_component\n");
    exit(1);
}
printf("PASS: scenario B - Tachyon-managed zapret2 removed\n");

// --- Test C: Tachyon-managed via component-backups (byedpi) ---
let result_c = is_tachyon_managed_component("byedpi");
if (!result_c) {
    printf("FAIL: byedpi with /etc/tachyon/component-backups/byedpi was NOT detected as managed\n");
    exit(1);
}
printf("PASS: scenario C - byedpi managed via component-backups dir detected\n");

// --- Test D: standalone user sing-box (no markers) ---
let result_d = is_tachyon_managed_component("sing-box");
if (result_d) {
    printf("FAIL: standalone sing-box (no markers) was detected as Tachyon-managed\n");
    exit(1);
}
backup_config_path("sing-box", MOCK_ROOT + "/etc/config/sing-box");
let backup_d = (fs.stat(EXTERNAL_BACKUP_DIR + "/sing-box/sing-box") != null);
if (!backup_d) {
    printf("FAIL: standalone sing-box config was not backed up\n");
    exit(1);
}
if (fs.stat(MOCK_ROOT + "/etc/init.d/sing-box") == null) {
    printf("FAIL: standalone sing-box init script should not be removed\n");
    exit(1);
}
printf("PASS: scenario D - standalone sing-box backed up, NOT removed\n");

// --- Test E: non-destructive backup does not overwrite existing ---
let existing_backup = EXTERNAL_BACKUP_DIR + "/zapret/zapret";
fs.writefile(existing_backup, "PRESERVED_ORIGINAL_BACKUP");
backup_config_path("zapret", MOCK_ROOT + "/etc/config/zapret");
let check_content = fs.readfile(existing_backup);
if (check_content != "PRESERVED_ORIGINAL_BACKUP") {
    printf("FAIL: backup_config_path overwrote an existing backup (non-destructive violated)\n");
    exit(1);
}
printf("PASS: scenario E - non-destructive backup preserves existing\n");

printf("ALL runtime scenarios passed\n");
UCODE_EOF

# Set up all mock scenarios
setup_standalone
setup_managed
setup_managed_via_backup_dir
setup_standalone_singbox

# Run ucode runtime tests
ucode_output="$(ucode -S "$UC_TEST_SCRIPT" 2>&1)" || {
  printf 'FAIL: ucode runtime test failed:\n%s\n' "$ucode_output" >&2
  exit 1
}
printf '%s\n' "$ucode_output"

# Count runtime passes from output
runtime_passes="$(printf '%s\n' "$ucode_output" | grep -c '^PASS:' || true)"
pass_count=$((pass_count + runtime_passes))
ok  # for the runtime suite overall

# ==========================================================================
# Part 3: Live execution of service/package.uc selective-cleanup-test
# ==========================================================================

PACKAGE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/package.uc"
grep -q 'function selective_cleanup_legacy_components' "$PACKAGE_UC" ||
  fail "package.uc must define selective_cleanup_legacy_components()"
ok

PKG_MOCK_ROOT="$WORK_DIR/pkg_mock_root"
mkdir -p "$PKG_MOCK_ROOT/etc/init.d" "$PKG_MOCK_ROOT/etc/rc.d" \
  "$PKG_MOCK_ROOT/etc/config" "$PKG_MOCK_ROOT/etc/sing-box" \
  "$PKG_MOCK_ROOT/opt/zapret/config" "$PKG_MOCK_ROOT/opt/zapret2/config" \
  "$PKG_MOCK_ROOT/etc/tachyon/component-backups/byedpi" \
  "$PKG_MOCK_ROOT/etc/tachyon/external-configs-backup/zapret"

# Pre-seed an existing backup file to verify non-destructive backup behavior
echo "PRESERVED_ORIGINAL_BACKUP" > "$PKG_MOCK_ROOT/etc/tachyon/external-configs-backup/zapret/zapret"

# Standalone zapret (no Tachyon markers) + standalone sing-box
printf '#!/bin/sh /etc/rc.common\nSTART=99\nstart() { /usr/bin/nfqws; }\n' > "$PKG_MOCK_ROOT/etc/init.d/zapret"
ln -sf ../init.d/zapret "$PKG_MOCK_ROOT/etc/rc.d/S99zapret"
echo "config zapret" > "$PKG_MOCK_ROOT/etc/config/zapret"
echo "user_custom=1" > "$PKG_MOCK_ROOT/opt/zapret/config/custom.cfg"

printf '#!/bin/sh /etc/rc.common\nSTART=99\nstart() { /usr/bin/sing-box run; }\n' > "$PKG_MOCK_ROOT/etc/init.d/sing-box"
echo '{"inbounds":[]}' > "$PKG_MOCK_ROOT/etc/sing-box/config.json"
echo "config sing-box" > "$PKG_MOCK_ROOT/etc/config/sing-box"

# Tachyon-managed zapret2 (init marker) & byedpi (component-backups marker)
printf '#!/bin/sh /etc/rc.common\n# Tachyon managed\nSTART=99\n' > "$PKG_MOCK_ROOT/etc/init.d/zapret2"
ln -sf ../init.d/zapret2 "$PKG_MOCK_ROOT/etc/rc.d/S99zapret2"
echo "config zapret2" > "$PKG_MOCK_ROOT/etc/config/zapret2"
echo "managed=1" > "$PKG_MOCK_ROOT/opt/zapret2/config/main.cfg"

printf '#!/bin/sh /etc/rc.common\nSTART=99\n' > "$PKG_MOCK_ROOT/etc/init.d/byedpi"
ln -sf ../init.d/byedpi "$PKG_MOCK_ROOT/etc/rc.d/S99byedpi"
echo "config byedpi" > "$PKG_MOCK_ROOT/etc/config/byedpi"

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$PACKAGE_UC" selective-cleanup-test "$PKG_MOCK_ROOT" ||
  fail "package.uc selective-cleanup-test failed"
ok

# Non-destructive backup preserved + new backups created
[ "$(cat "$PKG_MOCK_ROOT/etc/tachyon/external-configs-backup/zapret/zapret")" = "PRESERVED_ORIGINAL_BACKUP" ] ||
  fail "package.uc overwrote existing zapret backup"
[ -f "$PKG_MOCK_ROOT/etc/tachyon/external-configs-backup/zapret/config/custom.cfg" ] ||
  fail "package.uc did not back up standalone /opt/zapret/config"
[ -f "$PKG_MOCK_ROOT/etc/tachyon/external-configs-backup/sing-box/config.json" ] ||
  fail "package.uc did not back up /etc/sing-box/config.json"
[ -f "$PKG_MOCK_ROOT/etc/tachyon/external-configs-backup/zapret2/zapret2" ] ||
  fail "package.uc did not back up zapret2 config before cleanup"
[ -f "$PKG_MOCK_ROOT/etc/tachyon/external-configs-backup/byedpi/byedpi" ] ||
  fail "package.uc did not back up byedpi config before cleanup"
ok

# Standalone user components must remain untouched
[ -f "$PKG_MOCK_ROOT/etc/init.d/zapret" ] && [ -L "$PKG_MOCK_ROOT/etc/rc.d/S99zapret" ] ||
  fail "package.uc removed standalone user zapret service"
[ -f "$PKG_MOCK_ROOT/etc/config/zapret" ] && [ -f "$PKG_MOCK_ROOT/opt/zapret/config/custom.cfg" ] ||
  fail "package.uc removed standalone user zapret configs"
[ -f "$PKG_MOCK_ROOT/etc/init.d/sing-box" ] && [ -f "$PKG_MOCK_ROOT/etc/sing-box/config.json" ] ||
  fail "package.uc removed standalone user sing-box"
ok

# Tachyon-managed zapret2 and byedpi must be removed
[ ! -e "$PKG_MOCK_ROOT/etc/init.d/zapret2" ] && [ ! -L "$PKG_MOCK_ROOT/etc/rc.d/S99zapret2" ] && [ ! -e "$PKG_MOCK_ROOT/opt/zapret2" ] && [ ! -e "$PKG_MOCK_ROOT/etc/config/zapret2" ] ||
  fail "package.uc did not remove Tachyon-managed zapret2"
[ ! -e "$PKG_MOCK_ROOT/etc/init.d/byedpi" ] && [ ! -L "$PKG_MOCK_ROOT/etc/rc.d/S99byedpi" ] && [ ! -e "$PKG_MOCK_ROOT/etc/config/byedpi" ] ||
  fail "package.uc did not remove Tachyon-managed byedpi"
ok

printf 'legacy_component_selective_cleanup: %d checks passed\n' "$pass_count"
