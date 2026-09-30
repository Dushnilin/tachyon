#!/usr/bin/env bash
# The RPC surface used to be described three times by hand -- the command table
# in /usr/bin/tachyon, the Tachyon.AvailableMethods enum, and
# contracts/tachyon-rpc.json -- and the three drifted until the contract named a
# layer that does not exist and the enum carried a method the dispatcher never
# had. Two sources cannot disagree if one of them is generated, but only if
# regeneration actually runs.
#
# This fails when the generated files are stale. The generator is idempotent, so
# a clean run followed by --check is exactly "committed output matches the
# table".

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

GENERATOR="$ROOT_DIR/tools/generate_rpc_surface.js"
CONTRACT="$ROOT_DIR/contracts/tachyon-rpc.json"
TYPES="$ROOT_DIR/fe-app-tachyon/src/tachyon/types.ts"
DISPATCHER="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
READ_ENTRY="$ROOT_DIR/tachyon/files/usr/bin/tachyon-read"

for required in "$GENERATOR" "$CONTRACT" "$TYPES" "$DISPATCHER" "$READ_ENTRY"; do
  [ -f "$required" ] || fail "missing file: $required"
done

# Wipe and regenerate into a scratch copy so a failure here cannot leave the tree
# half-written, then compare.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cp "$CONTRACT" "$TYPES" "$scratch/"

if ! node "$GENERATOR" >/dev/null 2>&1; then
  fail "tools/generate_rpc_surface.js failed to run"
fi

if ! diff -q "$scratch/tachyon-rpc.json" "$CONTRACT" >/dev/null; then
  cp "$CONTRACT" "$scratch/generated.json"
  fail "contracts/tachyon-rpc.json is stale, run: node tools/generate_rpc_surface.js"
fi

if ! diff -q "$scratch/types.ts" "$TYPES" >/dev/null; then
  fail "fe-app-tachyon/src/tachyon/types.ts is stale, run: node tools/generate_rpc_surface.js"
fi

# And the check mode itself, which is what a future CI step would use.
node "$GENERATOR" --check >/dev/null 2>&1 ||
  fail "generator --check disagrees with the tree right after regenerating it"

# Every method in the contract must exist in the dispatcher, or the contract
# documents a command the router cannot run.
ucode -e '
  let fs = require("fs");
  let contract = json(fs.readfile(ARGV[0]));
  let dispatcher = fs.readfile(ARGV[1]);
  let known = {};
  for (let line in split(dispatcher, "\n")) {
    let m = match(line, /^[ ]{8}"?([a-z0-9_-]+)"?: \[/);
    if (m) known[m[1]] = true;
  }
  let missing = [];
  for (let method in contract.methods) {
    if (!known[method.name]) push(missing, method.name);
  }
  if (length(missing) > 0) {
    warn("contract describes commands the dispatcher does not have: ",
      join(missing, ", "), "\n");
    exit(1);
  }
  printf("contract covers %d commands, all present in the dispatcher\n",
    length(contract.methods));
' "$CONTRACT" "$DISPATCHER"

printf 'PASS: generated RPC surface is in sync with the command table\n'
