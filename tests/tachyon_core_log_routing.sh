#!/usr/bin/env bash
# tachyon-core below fatal must write to tmpfs instead of drowning syslog.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

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

# Non-fatal levels (warn, error, info, debug, trace) must write to tmpfs file.
for level in warn error info debug trace; do
  got="$(generate_log_level "$level" "$WORK_DIR/$level.out")"
  case "$got" in
    "none "*)  fail "log_level=$level must write to a file, syslog would drown" ;;
  esac
  case "$got" in
    *"$level") ;; *) fail "log_level=$level was not carried through: got '$got'" ;;
  esac
done

# fatal is a process-death event and stays in syslog.
got="$(generate_log_level fatal "$WORK_DIR/fatal.out")"
case "$got" in
  none\ *) ;; *) fail "log_level=fatal must not be redirected to a file: got '$got'" ;;
esac
case "$got" in
  *"fatal") ;; *) fail "log_level=fatal was not carried through: got '$got'" ;;
esac

# The log file lives on tmpfs: /etc and /usr are the overlay on flash.
for level in warn error info debug trace; do
  grep -Fq '"output": "/tmp/tachyon-core/tachyon-core.log"' "$WORK_DIR/$level.out" ||
    fail "log_level=$level must point the verbose log at tmpfs, not the flash overlay"
done

# Both init-script generators delegate to core.process with reset_log=true.
for file in "$ROOT_DIR/tachyon/files/usr/lib/components/action.uc" \
            "$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc"; do
  grep -Fq 'managed_core_init_script(' "$file" && grep -Fq ', true)' "$file" ||
    fail "$(basename "$file") must truncate the verbose log on service start"
done
grep -Fq 'contract.log_file' "$ROOT_DIR/tachyon/files/usr/lib/core/process.uc" ||
  fail "core/process.uc must truncate the verbose log when reset_log is true"

# panic maps to fatal for tachyon-core.
got_core="$(export TACHYON_CORE_VERSION_OVERRIDE="0.0.1-tachyon.0"; generate_log_level panic "$WORK_DIR/panic-core.out")"
case "$got_core" in
  *"fatal") ;; *) fail "log_level=panic was not mapped to fatal for tachyon-core: got '$got_core'" ;;
esac

printf 'tachyon-core log routing checks passed\n'
