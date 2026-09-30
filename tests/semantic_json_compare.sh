#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

COMPARE="$ROOT_DIR/tests/helpers/semantic_json_compare.js"

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

compare_output="$WORK_DIR/semantic-json.out"
if node "$COMPARE" "$WORK_DIR/expected.json" "$WORK_DIR/different-array-order.json" >"$compare_output" 2>&1; then
  fail "array order mismatch should be rejected"
fi

grep -Fq '$.outbounds[0].tag: "first" != "second"' "$compare_output" ||
  fail "array order mismatch reported unexpected diff"

printf 'semantic JSON compare checks passed\n'
