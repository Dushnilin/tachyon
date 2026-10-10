#!/usr/bin/env bash
# sing-box below warn must not write into syslog.
#
# The managed init script points procd's stderr at syslog, so every INFO line
# sing-box emits - one per connection - lands in the 128 KiB ring. Measured on a
# live router: 744 of 781 buffered lines were sing-box INFO, and the single
# hostapd AP-STA-DISCONNECTED had already been evicted. That is what made the
# networking problem undiagnosable for so long.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"

generate_log_level() {
  local level="$1" out="$2"
  local fixture="$WORK_DIR/$level.fixture.json"

  cat >"$fixture" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "$level",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "proxy_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"vless\",\"tag\":\"A\",\"server\":\"a.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}" ]
    }
  ]
}
JSON

  mkdir -p "${out}.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$out" "127.0.0.1" >/dev/null

  node -e '
    let s = "";
    process.stdin.on("data", d => s += d).on("end", () => {
      const log = JSON.parse(s).log;
      process.stdout.write((log.output || "none") + " " + log.level);
    });
  ' < "$out"
}

# info is the level a router can sit at for weeks unnoticed, and the one that
# floods. debug and trace are worse, so they have to be routed the same way.
for level in info debug trace; do
  got="$(generate_log_level "$level" "$WORK_DIR/$level.out")"
  case "$got" in
    "none "*)  fail "log_level=$level must write to a file, syslog would drown" ;;
  esac
  case "$got" in
    *"$level") ;; *) fail "log_level=$level was not carried through: got '$got'" ;;
  esac
done

# warn and above are the levels worth having in syslog; keep them there.
for level in warn error fatal; do
  got="$(generate_log_level "$level" "$WORK_DIR/$level.out")"
  case "$got" in
    none\ *) ;; *) fail "log_level=$level must not be redirected to a file: got '$got'" ;;
  esac
  case "$got" in
    *"$level") ;; *) fail "log_level=$level was not carried through: got '$got'" ;;
  esac
done

# The verbose file lives on tmpfs: /etc and /usr are the overlay on the flash
# that actually wears out, and a per-connection log would be written constantly.
for level in info debug trace; do
  grep -Fq '"output": "/tmp/sing-box/sing-box.log"' "$WORK_DIR/$level.out" ||
    fail "log_level=$level must point the verbose log at tmpfs, not the flash overlay"
done

# Both init-script generators truncate it on start so it cannot grow forever.
for file in "$ROOT_DIR/tachyon/files/usr/lib/components/action.uc" \
            "$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc"; do
  grep -Fq ': > /tmp/sing-box/sing-box.log' "$file" ||
    fail "$(basename "$file") must truncate the verbose log on service start"
done

# panic stays panic for standard sing-box, but maps to fatal for tachyon-core
got="$(generate_log_level panic "$WORK_DIR/panic.out")"
case "$got" in
  *"panic") ;; *) fail "log_level=panic was not preserved for sing-box: got '$got'" ;;
esac

got_core="$(export SB_VERSION_OVERRIDE="0.0.1-tachyon.0"; generate_log_level panic "$WORK_DIR/panic-core.out")"
case "$got_core" in
  *"fatal") ;; *) fail "log_level=panic was not mapped to fatal for tachyon-core: got '$got_core'" ;;
esac

printf 'sing-box log routing checks passed\n'