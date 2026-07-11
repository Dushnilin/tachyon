#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPARE="$ROOT_DIR/tests/helpers/semantic_json_compare.js"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/expected.json" <<'JSON'
{
  "outbounds": [
    { "tag": "first", "type": "direct" },
    { "tag": "second", "type": "block" }
  ],
  "route": {
    "rules": [
      { "domain_suffix": [ "example.org" ], "outbound": "first" }
    ],
    "auto_detect_interface": true
  }
}
JSON

cat >"$WORK_DIR/same.json" <<'JSON'
{
  "route": {
    "auto_detect_interface": true,
    "rules": [
      { "outbound": "first", "domain_suffix": [ "example.org" ] }
    ]
  },
  "outbounds": [
    { "type": "direct", "tag": "first" },
    { "type": "block", "tag": "second" }
  ]
}
JSON

node "$COMPARE" "$WORK_DIR/expected.json" "$WORK_DIR/same.json"

cat >"$WORK_DIR/different-array-order.json" <<'JSON'
{
  "outbounds": [
    { "tag": "second", "type": "block" },
    { "tag": "first", "type": "direct" }
  ],
  "route": {
    "rules": [
      { "domain_suffix": [ "example.org" ], "outbound": "first" }
    ],
    "auto_detect_interface": true
  }
}
JSON

if node "$COMPARE" "$WORK_DIR/expected.json" "$WORK_DIR/different-array-order.json" >/tmp/forkop-semantic-json.out 2>&1; then
  fail "array order mismatch should be rejected"
fi

grep -Fq '$.outbounds[0].tag: "first" != "second"' /tmp/forkop-semantic-json.out ||
  fail "array order mismatch reported unexpected diff"

printf 'semantic JSON compare checks passed\n'
