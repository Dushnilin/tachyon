#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Issue #76: the AI agent gateway is reachable from the whole LAN by default and
# GET /config answered with the raw /etc/config/tachyon — including bot_token.
# Two guards are asserted here:
#   1. the config masking covers bot_token / agent_api_token and friends;
#   2. the uhttpd symlink is published only when agent_api_token is set.

STATUS_UC="$TACHYON_LIB/diagnostics/status.uc"
INITD="$ROOT_DIR/tachyon/files/etc/init.d/tachyon"
MAKEFILE="$ROOT_DIR/tachyon/Makefile"

# ── 1. Masking ───────────────────────────────────────────────────────────────
cat >"$WORK_DIR/tachyon" <<'UCI'
config settings 'settings'
	option bot_token '123456:SUPERSECRET-BOT-TOKEN'
	option agent_api_token 'agent-secret-value'
	option enable_telegram '1'
	option warp_private_key 'warp-secret-key'
	option warp_access_token 'warp-access-token'
	option masque_access_token 'masque-access-token'
	option openvpn_password 'openvpn-pass'
	option yacd_secret_key 'yacd-secret'
	option engine 'sing-box'

config server 'srv'
	option protocol 'vless'
	option server_password 'server-pass'
UCI

masked="$(ucode -L "$TACHYON_LIB" "$STATUS_UC" tachyon-config-masked "$WORK_DIR/tachyon")"

for secret in SUPERSECRET-BOT-TOKEN agent-secret-value warp-secret-key \
              warp-access-token masque-access-token openvpn-pass yacd-secret; do
  if printf '%s' "$masked" | grep -qF "$secret"; then
    fail "masked config still exposes a secret: $secret"
  fi
done

# Non-secret options must survive, otherwise the endpoint is useless.
for keep in "option engine 'sing-box'" "option enable_telegram '1'"; do
  printf '%s' "$masked" | grep -qF "$keep" || fail "masked config dropped a harmless option: $keep"
done

# ── 2. Gateway symlink gate ──────────────────────────────────────────────────
# The reconciliation lives in ucode (service/initd.uc): the init.d script must
# stay free of UCI decisions (tests/shell_inventory.sh enforces that).
INITD_UC="$TACHYON_LIB/service/initd.uc"

grep -q "sync_agent_gateway_symlink" "$INITD_UC" ||
  fail "service/initd.uc must reconcile the agent gateway symlink"

helper="$(sed -n '/^function sync_agent_gateway_symlink()/,/^}/p' "$INITD_UC")"
[ -n "$helper" ] || fail "sync_agent_gateway_symlink() not found in initd.uc"
printf '%s' "$helper" | grep -q 'agent_api_token' ||
  fail "the sync helper must key the symlink on agent_api_token"
printf '%s' "$helper" | grep -q 'fs.unlink(AGENT_GATEWAY_LINK)' ||
  fail "the sync helper must remove the symlink when no token is set"
printf '%s' "$helper" | grep -q 'fs.symlink(AGENT_GATEWAY_TARGET, AGENT_GATEWAY_LINK)' ||
  fail "the sync helper must create the symlink when a token is set"

# start and reload must both reconcile it.
[ "$(grep -c 'sync_agent_gateway_symlink();' "$INITD_UC")" -ge 2 ] ||
  fail "start_service and reload_service must both reconcile the gateway symlink"

if grep -q "agent_api_token" "$INITD"; then
  fail "init.d must not read agent_api_token directly (uci decisions belong in ucode)"
fi

# Package install must not publish the gateway unconditionally any more.
if grep -qE '^[[:space:]]*ln -sf /usr/lib/cgi-bin/tachyon-agent \$\(1\)/www/cgi-bin/tachyon-agent' "$MAKEFILE"; then
  fail "package install must not create the /www/cgi-bin symlink unconditionally"
fi

postinst_gate="$(grep -c 'agent_api_token' "$MAKEFILE")"
[ "$postinst_gate" -ge 2 ] ||
  fail "postinst/postupgrade must gate the symlink on agent_api_token"

printf 'agent gateway exposure checks passed\n'
