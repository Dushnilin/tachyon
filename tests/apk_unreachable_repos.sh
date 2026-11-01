#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER_UC="$ROOT_DIR/tachyon/files/usr/lib/components/installer.uc"
INSTALL_SH="$ROOT_DIR/install.sh"

trap 'rm -rf "$WORK_DIR"' EXIT

BIN_DIR="$WORK_DIR/bin"
ETC_APK="$WORK_DIR/etc/apk"
REPOS_D="$ETC_APK/repositories.d"
TEST_TMP_DIR="$WORK_DIR/tmp"
PROBE_LOG="$WORK_DIR/probe.log"
APK_LOG="$WORK_DIR/apk.log"

mkdir -p "$BIN_DIR" "$REPOS_D" "$TEST_TMP_DIR"

cat >"$REPOS_D/distfeeds.list" <<'EOF'
https://fw.gl-inet.com/releases/mt798x/v24.10.0/25.12.5/apk/aarch64_cortex-a53/glinet/packages.adb
https://fw.gl-inet.com/releases/mt798x/v24.10.0/25.12.5/apk/aarch64_cortex-a53/packages/packages.adb
https://fw.gl-inet.com/releases/mt798x/v24.10.0/25.12.5/apk/aarch64_cortex-a53/luci/packages.adb
https://fw.gl-inet.com/releases/mt798x/v24.10.0/25.12.5/apk/aarch64_cortex-a53/routing/packages.adb
https://fw.gl-inet.com/releases/mt798x/v24.10.0/25.12.5/apk/aarch64_cortex-a53/telephony/packages.adb
https://fw.gl-inet.com/releases/mt798x/v24.10.0/25.12.5/targets/mediatek/filogic/packages/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci/packages.adb
EOF
cp "$REPOS_D/distfeeds.list" "$WORK_DIR/distfeeds.orig"

cat >"$BIN_DIR/curl" <<'EOF'
#!/bin/sh
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
printf 'curl %s\n' "$url" >>"$FAKE_PROBE_LOG"
case "$url" in
  *fw.gl-inet.com*) exit 28 ;;
  *downloads.openwrt.org*) exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat >"$BIN_DIR/apk" <<'EOF'
#!/bin/sh
printf 'apk %s\n' "$*" >>"$FAKE_APK_LOG"
if [ "$1" = "info" ] && [ "$2" = "-e" ]; then
  case " ${FAKE_APK_UNINSTALLED:-} " in
    *" $3 "*) exit 1 ;;
  esac
  exit 0
fi
for arg in "$@"; do
  if [ "$arg" = "--simulate" ]; then
    if [ -n "${FAKE_APK_SIMULATE_OUT:-}" ]; then
      printf '%s\n' "$FAKE_APK_SIMULATE_OUT" >&2
      exit 1
    fi
    if [ "${FAKE_APK_SIMULATE_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
  fi
done
if [ "${FAKE_APK_ONLINE_ADD_FAIL:-0}" = "1" ]; then
  for arg in "$@"; do
    if [ "$arg" = "--no-network" ] || [ "$arg" = "--virtual" ]; then
      exit 0
    fi
  done
  exit 1
fi
exit 0
EOF

chmod +x "$BIN_DIR/curl" "$BIN_DIR/apk"

export FAKE_PROBE_LOG="$PROBE_LOG"
export FAKE_APK_LOG="$APK_LOG"
export TACHYON_FORCE_PKG_MANAGER="apk"
export TACHYON_APK_REPOS_FILE="$ETC_APK/repositories"
export TACHYON_APK_REPOS_DIR="$REPOS_D"
export TACHYON_TMP_DIR="$TEST_TMP_DIR"

: >"$TEST_TMP_DIR/tachyon.apk"
: >"$TEST_TMP_DIR/luci-app-tachyon.apk"

# 1. Local .apk install when offline simulation succeeds: must use --no-network
# and /dev/null without probing remote repositories.
: >"$PROBE_LOG"
: >"$APK_LOG"
OFFLINE_CMD="$(
  FAKE_APK_SIMULATE_FAIL=0 PATH="$BIN_DIR:$PATH" command ucode -L "$TACHYON_LIB" -e '
    let inst = require("components.installer");
    print(inst.pkg_install_files_command([ getenv("TACHYON_TMP_DIR") + "/tachyon.apk", getenv("TACHYON_TMP_DIR") + "/luci-app-tachyon.apk" ], true));
  '
)"

case "$OFFLINE_CMD" in
  *"'--no-network' '--repositories-file' '/dev/null'"*) ;;
  *) fail "offline local apk install must disable network and repositories, got: $OFFLINE_CMD" ;;
esac

grep -q -- "--simulate --allow-untrusted --force-overwrite --no-network --repositories-file /dev/null" "$APK_LOG" ||
  fail "offline local apk install must run apk add --simulate first"

if [ -s "$PROBE_LOG" ]; then
  fail "offline local apk install must not probe remote repositories when simulation succeeds"
fi

# 2. Local .apk install when offline simulation fails (missing remote dependency):
# must probe each unique origin once, filter out fw.gl-inet.com, and pass the
# filtered repositories file without touching distfeeds.list on disk.
: >"$PROBE_LOG"
: >"$APK_LOG"
FALLBACK_OUT="$(
  FAKE_APK_SIMULATE_FAIL=1 PATH="$BIN_DIR:$PATH" command ucode -L "$TACHYON_LIB" -e '
    let inst = require("components.installer");
    let cmd = inst.pkg_install_files_command([ getenv("TACHYON_TMP_DIR") + "/tachyon.apk" ], true);
    let repo_file = inst.apk_filtered_repositories_file();
    print(cmd + "\nREPO_FILE=" + repo_file);
  '
)"

FALLBACK_CMD="$(printf '%s\n' "$FALLBACK_OUT" | sed -n '1p')"
FALLBACK_REPO_FILE="$(printf '%s\n' "$FALLBACK_OUT" | sed -n 's/^REPO_FILE=//p')"

case "$FALLBACK_CMD" in
  *"'--repositories-file'"*"'--force-missing-repositories' '--timeout' '15'"*) ;;
  *) fail "fallback apk install must pass filtered --repositories-file and timeout, got: $FALLBACK_CMD" ;;
esac

[ -n "$FALLBACK_REPO_FILE" ] && [ -f "$FALLBACK_REPO_FILE" ] ||
  fail "filtered repositories file was not created: '$FALLBACK_REPO_FILE'"

if grep -q "fw.gl-inet.com" "$FALLBACK_REPO_FILE"; then
  fail "filtered repositories file must not contain unreachable fw.gl-inet.com"
fi

grep -q "downloads.openwrt.org" "$FALLBACK_REPO_FILE" ||
  fail "filtered repositories file must preserve reachable downloads.openwrt.org feeds"

GLINET_PROBES="$(grep -c 'fw.gl-inet.com' "$PROBE_LOG" || true)"
[ "$GLINET_PROBES" -eq 1 ] ||
  fail "expected fw.gl-inet.com origin to be probed exactly once, got $GLINET_PROBES"

cmp -s "$REPOS_D/distfeeds.list" "$WORK_DIR/distfeeds.orig" ||
  fail "distfeeds.list on disk must never be modified"

# 3. Remote apk update & apk add <pkg> must also use filtered repositories,
# and apk del must run with --no-network --repositories-file /dev/null.
: >"$APK_LOG"
REMOTE_OUT="$(
  PATH="$BIN_DIR:$PATH" command ucode -L "$TACHYON_LIB" -e '
    let inst = require("components.installer");
    inst.pkg_remove_sing_box_conflict("sing-box");
    print(inst.pkg_list_update_command() + "\n" + inst.pkg_install_name_command("kmod-nft-tproxy"));
  '
)"

UPDATE_CMD="$(printf '%s\n' "$REMOTE_OUT" | sed -n '1p')"
ADD_NAME_CMD="$(printf '%s\n' "$REMOTE_OUT" | sed -n '2p')"

case "$UPDATE_CMD" in
  *"'apk' 'update' '--repositories-file'"*"'--force-missing-repositories' '--timeout' '15'"*) ;;
  *) fail "apk update must use filtered repositories file, got: $UPDATE_CMD" ;;
esac

case "$ADD_NAME_CMD" in
  *"'apk' 'add' '--repositories-file'"*"'--force-missing-repositories' '--timeout' '15' 'kmod-nft-tproxy'"*) ;;
  *) fail "apk add by name must use filtered repositories file, got: $ADD_NAME_CMD" ;;
esac

grep -q "apk del --no-network --repositories-file /dev/null --force-broken-world sing-box" "$APK_LOG" ||
  fail "apk del must use --no-network --repositories-file /dev/null, got: $(cat "$APK_LOG")"

# 4. Verify install.sh helper functions: offline bundle install and repo filtering.
: >"$PROBE_LOG"
: >"$APK_LOG"
(
  # shellcheck disable=SC1090
  TACHYON_INSTALLER_TEST=1 . "$INSTALL_SH"

  PATH="$BIN_DIR:$PATH"
  PKG_MANAGER="apk"
  PKG_IS_APK=1
  FETCHER="curl"
  TMP_DIR="$TEST_TMP_DIR"
  LOG_FILE="$WORK_DIR/install.log"
  APK_REPOS_FILE="$ETC_APK/repositories"
  APK_REPOS_DIR="$REPOS_D"
  QUIET=1

  export FAKE_APK_SIMULATE_FAIL=0
  pkg_install_local_bundle "$TEST_TMP_DIR/tachyon.apk" "$TEST_TMP_DIR/luci-app-tachyon.apk"
  grep -q "apk add --allow-untrusted --force-overwrite --no-network --repositories-file /dev/null $TEST_TMP_DIR/tachyon.apk $TEST_TMP_DIR/luci-app-tachyon.apk" "$APK_LOG" ||
    fail "install.sh offline bundle install did not pass --no-network --repositories-file /dev/null: $(cat "$APK_LOG")"

  : >"$PROBE_LOG"
  : >"$APK_LOG"
  APK_REPOS_PREPARED=0
  APK_FILTERED_REPOS_FILE=""
  export FAKE_APK_SIMULATE_FAIL=1
  pkg_install_local_bundle "$TEST_TMP_DIR/tachyon.apk"

  [ -n "$APK_FILTERED_REPOS_FILE" ] && [ -f "$APK_FILTERED_REPOS_FILE" ] ||
    fail "install.sh fallback did not generate APK_FILTERED_REPOS_FILE"
  if grep -q "fw.gl-inet.com" "$APK_FILTERED_REPOS_FILE"; then
    fail "install.sh filtered repositories file still contains fw.gl-inet.com"
  fi
  grep -q "downloads.openwrt.org" "$APK_FILTERED_REPOS_FILE" ||
    fail "install.sh filtered repositories file lost downloads.openwrt.org"
  grep -q "apk add --allow-untrusted --force-overwrite --force-missing-repositories --timeout 15 --repositories-file $APK_FILTERED_REPOS_FILE $TEST_TMP_DIR/tachyon.apk" "$APK_LOG" ||
    fail "install.sh fallback bundle install did not pass filtered repositories file: $(cat "$APK_LOG")"
  rm -f "$APK_FILTERED_REPOS_FILE"
)

cmp -s "$REPOS_D/distfeeds.list" "$WORK_DIR/distfeeds.orig" ||
  fail "install.sh modified distfeeds.list on disk"

# 5. Broken /etc/apk/world entries (apps no longer in repo or stale version pins)
# must be automatically healed before package transactions.
WORLD_FILE="$WORK_DIR/world"
cat >"$WORLD_FILE" <<'EOF'
busybox
curl=1.0.0
removed-repo-app
EOF

FAKE_APK_UNINSTALLED="removed-repo-app" \
FAKE_APK_SIMULATE_OUT="$(printf 'ERROR: unable to select packages:\n  removed-repo-app (no such package):\n    required by: world[removed-repo-app]\n  curl-8.0:\n    breaks: world[curl=1.0.0]')" \
TACHYON_APK_WORLD_FILE="$WORLD_FILE" \
PATH="$BIN_DIR:$PATH" command ucode -L "$TACHYON_LIB" -e '
  let h = require("components.helpers");
  h.sanitize_apk_world();
'

if grep -q "removed-repo-app" "$WORLD_FILE"; then
  fail "sanitize_apk_world must remove uninstalled broken package from world: $(cat "$WORLD_FILE")"
fi
grep -qx "curl" "$WORLD_FILE" ||
  fail "sanitize_apk_world must strip broken version pin from installed package curl: $(cat "$WORLD_FILE")"
grep -qx "busybox" "$WORLD_FILE" ||
  fail "sanitize_apk_world must keep healthy world entries: $(cat "$WORLD_FILE")"

# 6. Missing dependency in repository during local .apk install must register a
# virtual placeholder and succeed offline in both installer.uc and install.sh.
: >"$APK_LOG"
MISSING_DEP_RES="$(
  FAKE_APK_ONLINE_ADD_FAIL=1 \
  FAKE_APK_SIMULATE_OUT="$(printf 'ERROR: unable to select packages:\n  kmod-inet-diag (no such package):\n    required by: tachyon-1.7.7[kmod-inet-diag]')" \
  PATH="$BIN_DIR:$PATH" command ucode -L "$TACHYON_LIB" -e '
    let inst = require("components.installer");
    let res = inst.pkg_tx_install_files([ getenv("TACHYON_TMP_DIR") + "/tachyon.apk" ], true);
    print(res.success ? "OK" : "FAIL");
  '
)"
[ "$MISSING_DEP_RES" = "OK" ] ||
  fail "pkg_tx_install_files must succeed via offline virtual fallback when a repo dependency is missing"
grep -q "apk add --no-network --repositories-file /dev/null --force-non-repository --virtual kmod-inet-diag" "$APK_LOG" ||
  fail "pkg_tx_install_files must register virtual placeholder for missing repo dependency: $(cat "$APK_LOG")"

: >"$APK_LOG"
(
  # shellcheck disable=SC1090
  TACHYON_INSTALLER_TEST=1 . "$INSTALL_SH"

  PATH="$BIN_DIR:$PATH"
  PKG_MANAGER="apk"
  PKG_IS_APK=1
  FETCHER="curl"
  TMP_DIR="$TEST_TMP_DIR"
  LOG_FILE="$WORK_DIR/install.log"
  APK_REPOS_FILE="$ETC_APK/repositories"
  APK_REPOS_DIR="$REPOS_D"
  APK_WORLD_FILE="$WORLD_FILE"
  QUIET=1

  export FAKE_APK_ONLINE_ADD_FAIL=1
  export FAKE_APK_SIMULATE_OUT="ERROR: unable to select packages:
  kmod-inet-diag (no such package):
    required by: tachyon-1.7.7[kmod-inet-diag]"
  pkg_install_local_bundle "$TEST_TMP_DIR/tachyon.apk"
  grep -q "apk add --no-network --repositories-file /dev/null --force-non-repository --virtual kmod-inet-diag" "$APK_LOG" ||
    fail "install.sh must register virtual placeholder when online transaction fails: $(cat "$APK_LOG")"
)

printf 'PASS: apk unreachable repos\n'
