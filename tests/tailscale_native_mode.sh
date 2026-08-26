#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
RUNTIME_UC="$TACHYON_LIB/providers/tailscale/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

make_fixture() {
  local mode="$1"
  cat >"$WORK_DIR/ts_$mode.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "server": [
    {
      ".name": "ts_native",
      ".type": "server",
      "label": "Tailscale",
      "enabled": "1",
      "protocol": "tailscale",
      "routing_mode": "rules",
      "tailscale_mode": "$mode",
      "tailscale_hostname": "tachyon-ts",
      "tailscale_auth_key": "tskey-auth-secret"
    }
  ],
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"Alpha\",\"server\":\"alpha.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}"
      ]
    }
  ]
}
JSON
}

# Native mode: no sing-box endpoint and no MagicDNS DNS server must appear.
make_fixture native
generate_config "$WORK_DIR/ts_native.json" "$WORK_DIR/native.out"
grep -Fq '"type": "tailscale"' "$WORK_DIR/native.out" &&
  fail "native mode must not emit a tailscale endpoint"
grep -Fq 'tailscale-dns' "$WORK_DIR/native.out" &&
  fail "native mode must not emit a tailscale DNS server"

# Default (singbox) mode: endpoint present.
make_fixture singbox
generate_config "$WORK_DIR/ts_singbox.json" "$WORK_DIR/singbox.out"
grep -Fq '"type": "tailscale"' "$WORK_DIR/singbox.out" ||
  fail "singbox mode must emit a tailscale endpoint"

# Validator: native mode without tailscaled binary fails with install hint,
# even when sing-box lacks Tailscale support. fail_requirement() reports
# through `logger`, so a recording stub is installed on PATH.
STUB_BIN="$WORK_DIR/bin"
LOG_FILE="$WORK_DIR/logger.log"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/logger" <<SH
#!/usr/bin/env sh
printf '%s\n' "\$*" >> '$LOG_FILE'
exit 0
SH
chmod +x "$STUB_BIN/logger"

validate() {
  : >"$LOG_FILE"
  PATH="$STUB_BIN:$PATH" ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" \
    validate-runtime-fixture "$1" "{}"
}

if validate "$WORK_DIR/ts_native.json"; then
  fail "validator must reject native mode without tailscaled"
fi
grep -Fq "tailscaled is not installed" "$LOG_FILE" ||
  fail "validator must require the Tailscale component for native mode"

# With tailscaled available the validator passes for native mode.
cat >"$STUB_BIN/tailscaled" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$STUB_BIN/tailscaled"
validate "$WORK_DIR/ts_native.json" ||
  fail "validator must accept native mode with tailscaled available"
grep -Fq "tailscaled is not installed" "$LOG_FILE" &&
  fail "validator rejected native mode even though tailscaled is available"

# Native mode without an auth key is rejected: `tailscale up` would fall back
# to an interactive login and hang the runtime on a headless router.
sed 's/"tailscale_auth_key": "tskey-auth-secret"//' \
  "$WORK_DIR/ts_native.json" >"$WORK_DIR/ts_nokey.json"
if PATH="$STUB_BIN:$PATH" ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" \
    validate-runtime-fixture "$WORK_DIR/ts_nokey.json" "{}" >/dev/null 2>&1; then
  fail "validator must reject native mode without an auth key"
fi
grep -Fq "without an auth key" "$LOG_FILE" ||
  fail "validator message about missing auth key not reported"

# Runtime provider module: CLI surface responds without a config.
OUTPUT=$(ucode -L "$TACHYON_LIB" "$RUNTIME_UC" package-version)
[ "$OUTPUT" = "" ] || fail "package-version should be empty without binaries, got: $OUTPUT"

ucode -L "$TACHYON_LIB" "$RUNTIME_UC" status >/dev/null ||
  fail "status mode must always produce JSON"

printf 'config tailscale native mode checks passed\n'
