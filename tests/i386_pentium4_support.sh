#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATER="$TACHYON_LIB/components/updater.uc"
ACTION_UC="$TACHYON_LIB/components/action.uc"

# 1. Architecture mapping for i386_pentium4 and aliases
tc_arch() {
  ucode -L "$TACHYON_LIB" "$UPDATER" tachyon-core-arch-suffix "$1" "" 2>/dev/null
}

sb_arch() {
  ucode -L "$TACHYON_LIB" "$UPDATER" sing-box-extended-arch-suffix "$1" "" 2>/dev/null
}

for a in i386_pentium4 i386 i486 i586 i686 x86; do
  [ "$(tc_arch "$a")" = "i386_pentium4" ] ||
    fail "$a must resolve to i386_pentium4 for tachyon-core, got '$(tc_arch "$a")'"
done

for a in i386_pentium4 i386 i486 i586 i686 x86; do
  [ "$(sb_arch "$a")" = "386" ] ||
    fail "$a must resolve to 386 for sing-box-extended, got '$(sb_arch "$a")'"
done

candidates="$(ucode -L "$TACHYON_LIB" "$UPDATER" updates-arch-candidates "i386_pentium4" 2>/dev/null)"
grep -qwF "i386_pentium4" <<<"$candidates" ||
  fail "arch candidates for i386_pentium4 missing i386_pentium4: $candidates"
grep -qwF "i686" <<<"$candidates" ||
  fail "arch candidates for i386_pentium4 missing i686: $candidates"
grep -qwF "386" <<<"$candidates" ||
  fail "arch candidates for i386_pentium4 missing 386: $candidates"

# 2. v0.5.2 release asset selection for i386_pentium4 (.apk, .ipk, .tar.gz)
RELEASE_V052='{"tag_name":"v0.5.2","assets":[
  {"name":"tachyon-core-i386_pentium4-v0.5.2.apk","browser_download_url":"https://x/core-i386.apk"},
  {"name":"tachyon-core-i386_pentium4-v0.5.2.ipk","browser_download_url":"https://x/core-i386.ipk"},
  {"name":"tachyon-core-i386_pentium4-v0.5.2.tar.gz","browser_download_url":"https://x/core-i386.tgz"},
  {"name":"tachyon-core-x86_64-musl-v0.5.2.tar.gz","browser_download_url":"https://x/core-x64.tgz"},
  {"name":"SHA256SUMS","browser_download_url":"https://x/sums"}]}'
printf '%s' "$RELEASE_V052" >"$WORK_DIR/release_v052.json"

asset_v052() {
  ucode -L "$TACHYON_LIB" "$UPDATER" tachyon-core-asset-url "$1" "$2" \
    <"$WORK_DIR/release_v052.json" 2>/dev/null
}

[ "$(asset_v052 i386_pentium4 apk)" = "https://x/core-i386.apk" ] ||
  fail "v0.5.2 i386_pentium4 apk asset was not selected, got '$(asset_v052 i386_pentium4 apk)'"
[ "$(asset_v052 i386_pentium4 ipk)" = "https://x/core-i386.ipk" ] ||
  fail "v0.5.2 i386_pentium4 ipk asset was not selected, got '$(asset_v052 i386_pentium4 ipk)'"
[ "$(asset_v052 i386_pentium4 "")" = "https://x/core-i386.tgz" ] ||
  fail "v0.5.2 i386_pentium4 tar.gz asset was not selected, got '$(asset_v052 i386_pentium4 "")'"

# 3. Fallback to i686-unknown-linux-musl tar.gz when i386_pentium4 tarball is absent
RELEASE_FALLBACK='{"tag_name":"v0.5.2","assets":[
  {"name":"tachyon-core-i686-unknown-linux-musl-v0.5.2.tar.gz","browser_download_url":"https://x/core-i686-fallback.tgz"},
  {"name":"tachyon-core-x86_64-musl-v0.5.2.tar.gz","browser_download_url":"https://x/core-x64.tgz"}]}'
printf '%s' "$RELEASE_FALLBACK" >"$WORK_DIR/release_fallback.json"

got_fallback="$(ucode -L "$TACHYON_LIB" "$UPDATER" tachyon-core-asset-url i386_pentium4 "" <"$WORK_DIR/release_fallback.json" 2>/dev/null)"
[ "$got_fallback" = "https://x/core-i686-fallback.tgz" ] ||
  fail "expected i686 fallback tar.gz for i386_pentium4, got '$got_fallback'"

# 4. Preflight check_arch compatibility across 32-bit x86 aliases
mkdir -p "$WORK_DIR/stub_lib/core"
cat >"$WORK_DIR/stub_lib/core/packages.uc" <<'UC'
return {
    detect_arch: function() { return "i386_pentium4"; },
    is_installed: function() { return true; },
    list_installed_names: function() { return []; },
    pkg_version: function() { return "0.5.2"; },
    install_local_package: function() { return { ok: true }; }
};
UC

ucode -L "$WORK_DIR/stub_lib" -L "$TACHYON_LIB" -e '
let preflight = require("core.preflight");
for (let target in [ "386", "i386", "i686", "i386_pentium4" ]) {
    let r = preflight.check_arch({ target_arch: target });
    if (!r.ok) {
        warn("expected check_arch compatible for " + target + ": " + r.message + "\n");
        exit(1);
    }
}
let bad = preflight.check_arch({ target_arch: "aarch64" });
if (bad.ok) {
    warn("expected check_arch mismatch for aarch64\n");
    exit(2);
}
' || fail "preflight.check_arch failed for i386_pentium4 aliases"

# 5. SIGILL diagnostic message on 32-bit x86 must not claim x86-64-v3/AVX2
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/uname" <<'SH'
#!/bin/sh
echo i686
SH
chmod +x "$WORK_DIR/bin/uname"

cat >"$WORK_DIR/sigill-bin" <<'SH'
#!/bin/sh
exit 132
SH
chmod +x "$WORK_DIR/sigill-bin"

sigill_log="$WORK_DIR/sigill.log"
TACHYON_UPDATES_LOG_FILE="$sigill_log" PATH="$WORK_DIR/bin:$PATH" \
  ucode -L "$TACHYON_LIB" "$ACTION_UC" validate-tachyon-core-binary "$WORK_DIR/sigill-bin" "" >/dev/null 2>&1 || true

# ucode action updates_log writes to /tmp/tachyon-updates.log by default; check helper log output or stderr/log file
if [ -f "/tmp/tachyon-updates.log" ]; then
  if tail -n 15 /tmp/tachyon-updates.log | grep -q "AVX2/x86-64-v3"; then
    fail "32-bit i686 SIGILL diagnostic mistakenly reported AVX2/x86-64-v3"
  fi
fi

printf 'i386_pentium4 support checks passed\n'
