#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"

cat >"$WORK_DIR/bin/dig" <<'SH'
#!/usr/bin/env sh
case "$2" in
  alpha.example) printf '203.0.113.1\n' ;;
  beta.example) printf '203.0.113.2\n' ;;
esac
SH
chmod +x "$WORK_DIR/bin/dig"

cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env sh
output=""
payload=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -d)
      payload="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf '%s\n' "$payload" >"$FAKE_COUNTRY_PAYLOAD"
printf '[{"ip":"203.0.113.1","country":"DE"},{"ip":"203.0.113.2","country":"NL"}]\n' >"$output"
printf '200'
SH
chmod +x "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/runner.uc" <<'UCODE'
let country = require("singbox.country");

function fail(message) {
    die(message + "\n");
}

let detected = country.detect({
    alpha: "alpha.example",
    beta: "beta.example"
}, {});
if (detected.alpha != "DE" || detected.beta != "NL")
    fail("country.is response was not mapped to outbound tags");

let cached = country.detect({
    renamed: "alpha.example"
}, {
    servers: { old: "alpha.example" },
    outboundMetadata: { countries: { old: "DE" } }
});
if (cached.renamed != "DE")
    fail("country cache should be reused by server after an outbound tag changes");
UCODE

FAKE_COUNTRY_PAYLOAD="$WORK_DIR/payload.json" \
PODKOP_COUNTRY_IS_URL="https://country.invalid/" \
PATH="$WORK_DIR/bin:$PATH" \
  ucode -L "$PODKOP_LIB" "$WORK_DIR/runner.uc"

grep -Fq '203.0.113.1' "$WORK_DIR/payload.json" ||
  fail "country.is request did not contain the first resolved IP"
grep -Fq '203.0.113.2' "$WORK_DIR/payload.json" ||
  fail "country.is request did not contain the second resolved IP"

printf 'country detection regression checks passed\n'
