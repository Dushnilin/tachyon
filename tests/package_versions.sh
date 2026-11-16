#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGES_UC="${PACKAGES_UC:-$ROOT_DIR/tachyon/files/usr/lib/core/packages.uc}"

cat >"$WORK_DIR/apk" <<'SH'
#!/usr/bin/env sh
set -eu

case "$*" in
  "info -e fptn")
    exit 0
    ;;
  "list --installed --manifest fptn"|"list --installed --manifest")
    exit 1
    ;;
  "list --installed fptn")
    if [ "${FAKE_APK_LIST_EMPTY:-0}" = "1" ]; then
      exit 1
    fi
    printf '<fptn> fptn-1.2.3-r1 aarch64_cortex-a53 {feeds/base/fptn} [installed]\n'
    ;;
  "info -v fptn")
    printf 'fptn: fptn\n'
    ;;
  "list --available --manifest tachyon-core-mini")
    if [ -n "${FAKE_APK_LOG:-}" ]; then
      printf '%s\n' "$*" >>"$FAKE_APK_LOG"
    fi
    exit 0
    ;;
  "query --from repositories --available --format json --fields name,version tachyon-core-mini")
    printf '%s\n' "$*" >>"${FAKE_APK_LOG:?}"
    case "${FAKE_APK_QUERY_RESULT:-valid}" in
      valid) printf '%s\n' '[{"name":"tachyon-core-mini","version":"0.4.5-r1"}]' ;;
      empty) printf '%s\n' '[]' ;;
      malformed) printf '%s\n' 'not-json' ;;
      wrong-name) printf '%s\n' '[{"name":"tachyon-core","version":"9.9.9-r1"}]' ;;
      provider-first) printf '%s\n' '[{"name":"tachyon-core","version":"9.9.9-r1"},{"name":"tachyon-core-mini","version":"0.4.5-r1"}]' ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$WORK_DIR/apk"

version="$(PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-version fptn)"
[ "$version" = "1.2.3-r1" ] ||
  fail "APK v3 installed package version was parsed as '$version'"

invalid_version="$(FAKE_APK_LIST_EMPTY=1 PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-version fptn)"
[ -z "$invalid_version" ] ||
  fail "APK v3 description was accepted as package version '$invalid_version'"

: >"$WORK_DIR/apk.log"
available_version="$(FAKE_APK_LOG="$WORK_DIR/apk.log" PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-available-version tachyon-core-mini)"
[ "$available_version" = "0.4.5-r1" ] ||
  fail "APK v3 available package version was parsed as '$available_version'"
grep -Fxq 'query --from repositories --available --format json --fields name,version tachyon-core-mini' "$WORK_DIR/apk.log" ||
  fail "APK available version lookup must query repository packages explicitly"
if grep -Fq 'list --available --manifest tachyon-core-mini' "$WORK_DIR/apk.log"; then
  fail "APK available version lookup must not use installed-only manifest mode"
fi

provider_version="$(FAKE_APK_QUERY_RESULT=provider-first FAKE_APK_LOG="$WORK_DIR/apk.log" PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-available-version tachyon-core-mini)"
[ "$provider_version" = "0.4.5-r1" ] ||
  fail "APK provider result replaced the exact package version '$provider_version'"

for result in empty malformed wrong-name; do
  invalid_available_version="$(FAKE_APK_QUERY_RESULT="$result" FAKE_APK_LOG="$WORK_DIR/apk.log" PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-available-version tachyon-core-mini)"
  [ -z "$invalid_available_version" ] ||
    fail "APK v3 $result query result was accepted as version '$invalid_available_version'"
done

printf 'Package version checks passed\n'
