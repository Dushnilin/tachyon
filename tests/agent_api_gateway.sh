#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
AGENT_API_UC="$TACHYON_LIB/service/agent_api.uc"
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

# 3. The gateway symlink must be published only when agent_api_token is set.
#    Issue #76: the handler used to be published on every install/upgrade, so
#    any LAN client could read /config and got the raw UCI config with the bot
#    token. Assert the gate instead of the old unconditional symlink.
if grep -Fq 'ln -sf /usr/lib/cgi-bin/tachyon-agent $(1)/www/cgi-bin/tachyon-agent' "$MAKEFILE"; then
  fail "Makefile Package/tachyon/install must not package /www/cgi-bin/tachyon-agent unconditionally"
fi

[ "$(grep -c 'agent_api_token' "$MAKEFILE")" -ge 2 ] ||
  fail "Makefile postinst/postupgrade must gate the symlink on agent_api_token"

grep -Fq 'ln -sf /usr/lib/cgi-bin/tachyon-agent /www/cgi-bin/tachyon-agent' "$MAKEFILE" ||
  fail "Makefile must still be able to create the symlink when the gateway is enabled"

grep -Fq 'rm -f /www/cgi-bin/tachyon-agent' "$MAKEFILE" ||
  fail "Makefile must remove the gateway symlink when no token is configured"

# 4. build.sh must mirror the Makefile gate
if grep -Fq 'ln -sf /usr/lib/cgi-bin/tachyon-agent "$output_root/www/cgi-bin/tachyon-agent"' "$BUILD_SH"; then
  fail "build.sh build_backend_root must not package the symlink unconditionally"
fi

[ "$(grep -c 'agent_api_token' "$BUILD_SH")" -ge 1 ] ||
  fail "build.sh must gate the symlink on agent_api_token"

# 5. The service must reconcile the symlink at start/reload (ucode, not init.d)
grep -Fq 'sync_agent_gateway_symlink' "$TACHYON_LIB/service/initd.uc" ||
  fail "service/initd.uc must reconcile the agent gateway symlink"

printf 'agent_api gateway tests passed\n'
