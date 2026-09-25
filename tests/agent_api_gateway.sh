#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_API_UC="$ROOT_DIR/tachyon/files/usr/lib/service/agent_api.uc"
MAKEFILE="$ROOT_DIR/tachyon/Makefile"
BUILD_SH="$ROOT_DIR/build.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. agent_api.uc must use core.uci dot-path getter for agent_api_token
grep -Fq 'uci.get(CONFIG_NAME + ".settings.agent_api_token")' "$AGENT_API_UC" ||
  fail "agent_api.uc must use uci.get() to resolve agent_api_token dot-path"

if grep -n -E 'c\.get\(.*agent_api_token' "$AGENT_API_UC" >/dev/null 2>&1; then
  fail "agent_api.uc must not call c.get on raw UCI cursor for dot-paths (fails to parse)"
fi

# 2. agent_api.uc must use common.background_command for reload to avoid hanging HTTP CGI
grep -Fq 'system(common.background_command("/usr/bin/tachyon reload"))' "$AGENT_API_UC" ||
  fail "agent_api.uc must use common.background_command for tachyon reload"

# 3. Makefile must install and restore /www/cgi-bin/tachyon-agent symlink
grep -Fq 'ln -sf /usr/lib/cgi-bin/tachyon-agent $(1)/www/cgi-bin/tachyon-agent' "$MAKEFILE" ||
  fail "Makefile Package/tachyon/install must package /www/cgi-bin/tachyon-agent symlink"

grep -Fq 'ln -sf /usr/lib/cgi-bin/tachyon-agent /www/cgi-bin/tachyon-agent' "$MAKEFILE" ||
  fail "Makefile must restore /www/cgi-bin/tachyon-agent symlink on postinst/postupgrade"

# 4. build.sh must mirror Makefile and package the symlink
grep -Fq 'ln -sf /usr/lib/cgi-bin/tachyon-agent "$output_root/www/cgi-bin/tachyon-agent"' "$BUILD_SH" ||
  fail "build.sh build_backend_root must package /www/cgi-bin/tachyon-agent symlink"

printf 'agent_api gateway tests passed\n'
