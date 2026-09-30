#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

ACL="$ROOT_DIR/tachyon/files/usr/share/rpcd/acl.d/luci-app-tachyon.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$ACL" ] || fail "LuCI ACL file is missing"

# BusyBox is a multi-call binary (sh, wget, nc, rm, dd, ...). Granting LuCI
# generic exec access to it effectively broadens the web UI capability far
# beyond the explicit commands Tachyon needs. Keep this regression guard next
# to the ACL so the capability cannot be reintroduced accidentally.
if grep -Fq '"/bin/busybox"' "$ACL"; then
  fail "LuCI ACL must not grant generic /bin/busybox exec access"
fi

# The file is JSON consumed by rpcd; catch accidental syntax damage without
# depending on jq, which is not guaranteed to exist in OpenWrt test images.
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$ACL"

echo "OK: LuCI ACL keeps generic BusyBox execution disabled"
