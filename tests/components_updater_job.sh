#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
CLI_UC="$TACHYON_BIN"
UPDATER="$ROOT_DIR/tachyon/files/usr/lib/components/updater.uc"
UPDATES_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"
INSTALLER_UC="$ROOT_DIR/tachyon/files/usr/lib/components/installer.uc"

ucode() {
  local has_L=0
  for arg in "$@"; do
    if [ "$arg" = "-L" ]; then
      has_L=1
      break
    fi
  done
  if [ "$has_L" -eq 1 ]; then
    command ucode "$@"
  else
    command ucode -L "$TACHYON_LIB" "$@"
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

write_state() {
  local name="$1"
  local content="$2"

  printf '%s\n' "$content" >"$WORK_DIR/$name.json"
  printf '%s\n' "$WORK_DIR/$name.json"
}

assert_eq "/tmp/jobs/abc-1_2.json" \
  "$(ucode "$UPDATER" updates-job-state-path /tmp/jobs abc-1_2)" \
  "valid job state path"

if ucode "$UPDATER" updates-job-state-path /tmp/jobs '../bad' >/dev/null 2>&1; then
  fail "invalid job id should be rejected"
fi

assert_eq outdated \
  "$(ucode -- "$UPDATER" updates-status-from-compare -1)" \
  "outdated compare status"
assert_eq latest \
  "$(ucode -- "$UPDATER" updates-status-from-compare 0)" \
  "latest compare status"
assert_eq dev \
  "$(ucode -- "$UPDATER" updates-status-from-compare 1)" \
  "dev compare status"
if ucode -- "$UPDATER" updates-status-from-compare invalid >/dev/null 2>&1; then
  fail "invalid compare status should be rejected"
fi

assert_eq "$(printf 'Latest version is installed\tcomponent is up to date (1.0)')" \
  "$(ucode "$UPDATER" updates-check-result-row component 1.0 1.0 latest)" \
  "latest check result"
assert_eq "$(printf 'Update is available\tcomponent update is available: 1.0 -> 2.0')" \
  "$(ucode "$UPDATER" updates-check-result-row component 1.0 2.0 outdated)" \
  "outdated check result"
assert_eq "$(printf 'Installed version is newer than release\tcomponent installed version is newer than upstream release: 2.0 -> 1.0')" \
  "$(ucode "$UPDATER" updates-check-result-row component 2.0 1.0 dev)" \
  "dev check result"
if ucode "$UPDATER" updates-check-result-row component 1.0 2.0 invalid >/dev/null 2>&1; then
  fail "invalid check result status should be rejected"
fi

[ ! -e "$ROOT_DIR/tachyon/files/usr/lib/updater.sh" ] ||
  fail "updater.sh shell owner must be removed"
grep -Fq 'component_action: [ "components/action.uc", "component-action", 2 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch direct component_action through components/action.uc"
grep -Fq 'component-action-async' "$UPDATES_UC" ||
  fail "components/updates.uc must own component action async"
grep -Fq 'component-action-status' "$UPDATES_UC" ||
  fail "components/updates.uc must own component action status"
grep -Fq 'components/action.uc' "$UPDATES_UC" ||
  fail "component action worker must execute components/action.uc directly"
grep -Fq 'tachyon_core/runtime.uc' "$UPDATES_UC" ||
  fail "components/updates.uc must delegate core service/config work to tachyon_core/runtime.uc"
if grep -n -E 'function (configure_core_service|rebuild_core_config|save_core_config_file|service_listen_address|managed_core_service_text)' "$UPDATES_UC" >/dev/null 2>&1; then
  fail "components/updates.uc must not duplicate tachyon_core/runtime.uc service/config ownership"
fi
if grep -Fq 'save-core-config-file-fixture' "$UPDATES_UC"; then
  fail "components/updates.uc must not expose core config save fixtures owned by tachyon_core/runtime.uc"
fi
grep -Fq 'component_action_async: [ "components/updates.uc", "component-action-async", 2 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch component_action_async through components/updates.uc"
grep -Fq 'component_action_status: [ "components/updates.uc", "component-action-status", 1 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch component_action_status through components/updates.uc"
grep -Fq 'require("core.uci")' "$ACTION_UC" ||
  fail "components/action.uc must use core.uci for component UCI mutations"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"|command_exists\("uci"\)' "$ACTION_UC" >/dev/null 2>&1; then
  fail "components/action.uc must not own direct UCI cursor or CLI calls"
fi
grep -Fq 'tachyon_status_running_with_timeout()' "$ACTION_UC" ||
  fail "components/action.uc must use bounded Tachyon status checks for component actions"
grep -Fq 'if (!pkg_ok) {' "$ACTION_UC" ||
  fail "tachyon-core package installs must restore backup on failure"
grep -Fq 'let package_spec = package_name + "=" + package_version;' "$INSTALLER_UC" ||
  fail "APK installs must pin the concrete package version instead of selecting a provider"
grep -Fq 'install_staged_file(backup_binary, TACHYON_CORE_BIN, "0755");' "$ACTION_UC" ||
  fail "tachyon-core installs must restore backup binary on failure"
grep -Fq 'install_managed_core_service_script();' "$ACTION_UC" ||
  fail "tachyon-core installs must ensure managed core service script"
if grep -Fq 'command_success_from_args([ SERVICE_INIT, "status" ])' "$ACTION_UC"; then
  fail "components/action.uc must not call init.d status without a timeout"
fi
status_timeout_line="$(grep -n '^function tachyon_status_running_with_timeout()' "$ACTION_UC" | cut -d: -f1)"
capture_state_line="$(grep -n '^function capture_tachyon_running_state()' "$ACTION_UC" | cut -d: -f1)"
[ -n "$status_timeout_line" ] && [ -n "$capture_state_line" ] && [ "$status_timeout_line" -lt "$capture_state_line" ] ||
  fail "components/action.uc must declare bounded status helper before capture_tachyon_running_state for OpenWrt ucode"
init_line="$(grep -n '^function init_tmp_dir()' "$ACTION_UC" | cut -d: -f1)"
tmp_file_line="$(grep -n '^function make_tmp_file' "$ACTION_UC" | cut -d: -f1)"
[ -n "$init_line" ] && [ -n "$tmp_file_line" ] && [ "$init_line" -lt "$tmp_file_line" ] ||
  fail "components/action.uc must declare init_tmp_dir before make_tmp_file for OpenWrt ucode"

cat >"$WORK_DIR/action-command-success.uc" <<'UCODE'
let common = require("core.common");
let command_from_args = common.command_from_args;
let shell_quote = common.shell_quote;
let command_status = common.command_status;

function command_success(command) {
    return command_status("(" + command + ") >/dev/null 2>&1") == 0;
}

let output_path = ARGV[0] || "";
if (output_path == "" ||
    !command_success(command_from_args([ "printf", "%s", "extracted payload" ]) + " >" + shell_quote(output_path)))
    exit(1);
UCODE
command_success_output="$WORK_DIR/command-success-output"
ucode "$WORK_DIR/action-command-success.uc" "$command_success_output" ||
  fail "components/action.uc command_success should allow commands with explicit output redirection"
assert_eq "extracted payload" "$(cat "$command_success_output")" \
  "component command success preserves explicit output redirection"

awk '
{ sub(/\r$/, "") }
prev2 == "    remove_file(archive_file);" &&
prev1 == "" &&
$0 == "    let new_version = validate_tachyon_core_binary(tmp_binary, cmp.tmp_dir_path());" {
  safe_validation = 1
}
{ prev2 = prev1; prev1 = $0 }
END { exit safe_validation ? 0 : 1 }
' "$ACTION_UC" ||
  fail "tachyon-core binary validation must release the archive first to avoid OpenWrt OOM"
grep -Fq 'install_staged_file(tmp_binary, TACHYON_CORE_BIN, "0755")' "$ACTION_UC" ||
  fail "tachyon-core binary installation must support moving from tmpfs to overlay"
if grep -Fq 'fs.rename(tmp_binary, TACHYON_CORE_BIN)' "$ACTION_UC"; then
  fail "tachyon-core installation must not rename directly across OpenWrt filesystems"
fi
grep -Fq 'command_success_from_args([ "cp", "-p", backup_bin, TACHYON_CORE_BIN ])' "$ACTION_UC" ||
  fail "component rollback must restore backups across filesystems"

release_json="$(cat <<'JSON'
{
  "tag_name": "1.2.3",
  "html_url": "https://example.com/release",
  "assets": [
    {"name": "tachyon_1.2.3.ipk", "browser_download_url": "https://example.com/backend.ipk"},
    {"name": "luci-app-tachyon_1.2.3.ipk", "browser_download_url": "https://example.com/app.ipk"},
    {"name": "luci-i18n-tachyon-ru_1.2.3.ipk", "browser_download_url": "https://example.com/i18n.ipk"}
  ]
}
JSON
)"

assert_eq "$(printf 'https://example.com/release\ttachyon_1.2.3.ipk\thttps://example.com/backend.ipk\tluci-app-tachyon_1.2.3.ipk\thttps://example.com/app.ipk\tluci-i18n-tachyon-ru_1.2.3.ipk\thttps://example.com/i18n.ipk')" \
  "$(printf '%s' "$release_json" | ucode "$UPDATER" tachyon-release-plan 1.2.3 ipk 1)" \
  "tachyon release plan with i18n"
assert_eq "$(printf 'https://example.com/release\ttachyon_1.2.3.ipk\thttps://example.com/backend.ipk\tluci-app-tachyon_1.2.3.ipk\thttps://example.com/app.ipk\t\t')" \
  "$(printf '%s' "$release_json" | ucode "$UPDATER" tachyon-release-plan 1.2.3 ipk 0)" \
  "tachyon release plan without i18n"
if printf '%s' "$release_json" | ucode "$UPDATER" tachyon-release-plan 9.9.9 ipk 0 >/dev/null 2>&1; then
  fail "tachyon release plan should reject tag mismatch"
fi
missing_i18n_json="$(cat <<'JSON'
{
  "tag_name": "1.2.3",
  "html_url": "https://example.com/release",
  "assets": [
    {"name": "tachyon_1.2.3.ipk", "browser_download_url": "https://example.com/backend.ipk"},
    {"name": "luci-app-tachyon_1.2.3.ipk", "browser_download_url": "https://example.com/app.ipk"}
  ]
}
JSON
)"
if printf '%s' "$missing_i18n_json" | ucode "$UPDATER" tachyon-release-plan 1.2.3 ipk 1 >/dev/null 2>&1; then
  fail "tachyon release plan should require i18n asset when requested"
fi

ucode "$UPDATER" tachyon-release-version-valid 1.2.3 ||
  fail "three-part Tachyon release version should be valid"
for invalid_version in v1.2.3 1.2 1.2.3.4 1.2.3-1 1.2.3-r1; do
  if ucode "$UPDATER" tachyon-release-version-valid "$invalid_version" >/dev/null 2>&1; then
    fail "invalid Tachyon release version was accepted: $invalid_version"
  fi
done
assert_eq "-1" "$(ucode "$UPDATER" tachyon-release-version-compare 1.2.3 1.2.4)" \
  "three-part Tachyon release version comparison"

assert_eq "0.5.7" \
  "$(printf 'tachyon-core version 0.5.7\n\nEnvironment: rust linux/amd64\n' | ucode "$UPDATER" stdin-first-line-last-field)" \
  "tachyon-core binary version parsing"

component_actions_dir="$WORK_DIR/component-actions"
fake_lib="$WORK_DIR/lib"
mkdir -p "$fake_lib/components" "$fake_lib/config" "$fake_lib/core"
cp "$UPDATES_UC" "$fake_lib/components/updates.uc"
# components/helpers.uc is a real dependency of updates.uc (component_worker_env
# asks it for the router timezone), so the fixture has to carry it. Without it the
# require fails, component_worker_env() throws, and the worker never starts - which
# showed up as a job stuck at running:true rather than as a load error.
cp "$TACHYON_LIB/components/helpers.uc" "$fake_lib/components/helpers.uc"
cp "$TACHYON_LIB/config/connections.uc" "$fake_lib/config/connections.uc"
cp "$TACHYON_LIB/core/"*.uc "$fake_lib/core/"
cp -r "$TACHYON_LIB/providers" "$fake_lib/"
cat >"$fake_lib/components/action.uc" <<'UCODE'
#!/usr/bin/env ucode
if ((ARGV[0] || "") == "component-action") {
  printf('{"success":true,"kind":"component","component":"%s","action":"%s","message":"done","current_version":"1.0","latest_version":"1.0","changed":0,"status":"latest"}\n', ARGV[1], ARGV[2]);
  exit(0);
}
exit(1);
UCODE

start_json="$(TACHYON_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
  ucode -L "$TACHYON_LIB" "$UPDATES_UC" component-action-async tachyon-core check_update)"
job_id="$(JSON_VALUE="$start_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (!value.success || !value.job_id) {
  process.exit(1);
}
process.stdout.write(value.job_id);
NODE
)"
[ -n "$job_id" ] || fail "component action async should return a job id"

status_json=""
for _ in 1 2 3 4 5; do
  status_json="$(TACHYON_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
    ucode -L "$TACHYON_LIB" "$UPDATES_UC" component-action-status "$job_id")"
  JSON_VALUE="$status_json" node - <<'NODE' && break || true
const value = JSON.parse(process.env.JSON_VALUE);
process.exit(value.running === false ? 0 : 1);
NODE
  sleep 1
done

JSON_VALUE="$status_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== true || value.component !== "tachyon-core" ||
    value.action !== "check_update" || value.message !== "done" || value.exit_code !== 0) {
  console.error("component action async/status state mismatch");
  process.exit(1);
}
NODE

start_json="$(TACHYON_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
  ucode -L "$TACHYON_LIB" "$UPDATES_UC" component-action-async tachyon_core check_update)"
job_id="$(JSON_VALUE="$start_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (!value.success || !value.job_id) {
  process.exit(1);
}
process.stdout.write(value.job_id);
NODE
)"
[ -n "$job_id" ] || fail "component action async should accept tachyon_core alias"

status_json=""
for _ in 1 2 3 4 5; do
  status_json="$(TACHYON_LIB="$fake_lib" UPDATES_JOB_DIR="$component_actions_dir" \
    ucode -L "$TACHYON_LIB" "$UPDATES_UC" component-action-status "$job_id")"
  JSON_VALUE="$status_json" node - <<'NODE' && break || true
const value = JSON.parse(process.env.JSON_VALUE);
process.exit(value.running === false ? 0 : 1);
NODE
  sleep 1
done

JSON_VALUE="$status_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== true || value.component !== "tachyon-core" ||
    value.action !== "check_update" || value.message !== "done" || value.exit_code !== 0) {
  console.error("component action tachyon_core alias state mismatch");
  process.exit(1);
}
NODE

sample_release_json="$(cat <<'JSON'
{
  "tag_name": "v1.0.1",
  "html_url": "https://example.com/sample-release",
  "assets": [
    {"name": "sample_v1.0.1_aarch64_generic.zip", "browser_download_url": "https://example.com/aarch64.zip"},
    {"name": "sample_v1.0.1_mipsel_24kc.zip", "browser_download_url": "https://example.com/mipsel.zip"}
  ]
}
JSON
)"

assert_eq "$(printf 'mipsel_24kc\tsample_v1.0.1_mipsel_24kc.zip\thttps://example.com/mipsel.zip\thttps://example.com/sample-release\tv1.0.1')" \
  "$(printf '%s' "$sample_release_json" | ucode "$UPDATER" release-select-arch-suffix-asset zip 'mipsel_24kc aarch64_generic')" \
  "release arch suffix selector"
[ -z "$(printf '%s' "$sample_release_json" | ucode "$UPDATER" release-select-arch-suffix-asset zip 'arm_cortex-a7')" ] ||
  fail "release arch suffix selector should be empty for missing arch"

running="$(write_state running '{"running":true,"pid":"123","started_at":100}')"
assert_eq "$(printf 'pid\t123\t0')" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$running" 105 15)" \
  "alive candidate within grace"
assert_eq "$(printf 'pid\t123\t1')" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$running" 120 15)" \
  "alive candidate after grace"

invalid_pid="$(write_state invalid-pid '{"running":true,"pid":"","started_at":100}')"
assert_eq "skip" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$invalid_pid" 105 15)" \
  "invalid pid within grace"
assert_eq "stale" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$invalid_pid" 120 15)" \
  "invalid pid after grace"

finished="$(write_state finished '{"running":false,"pid":"123","started_at":100}')"
assert_eq "skip" \
  "$(ucode "$UPDATER" updates-job-refresh-plan "$finished" 120 15)" \
  "finished job refresh"

stale_json="$(ucode "$UPDATER" updates-mark-stale-job-state "$invalid_pid")"
JSON_VALUE="$stale_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.running !== false || value.success !== false || value.exit_code !== null) {
  console.error("stale state shape mismatch");
  process.exit(1);
}
NODE

printf 'component updater job checks passed\n'
