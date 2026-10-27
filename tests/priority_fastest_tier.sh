#!/usr/bin/env bash
# Issue #244: a priority group picked the slowest node of a tier.
#
# The tier was walked in filter order and the first living node won, so the
# group ended up on whatever node happened to be first in the list - not the
# quickest one. The expected behaviour: the tier is entered on its fastest
# node, and the next tier is only used when the current one fails.
#
# Two things have to hold:
#   * the choice is by the lowest measured delay, not by list order;
#   * a tier is not skipped because a node in it is dead - the first living
#     node of the tier wins, and only a fully dead tier moves on.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CONNECTIONS="$TACHYON_LIB/config/connections.uc"

# 1. pick_fastest defaults to on, so a group that says nothing about it picks
#    the fastest node of the tier.
out="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let connections = require("config.connections");

function check(condition, message) {
    if (!condition) {
        warn(message + "\n");
        exit(1);
    }
}

let fixture = {
    balancer: [
        {
            ".name": "pg_fast",
            ".type": "balancer",
            enabled: "1",
            balancer_type: "priority",
            name: "Fast"
        },
        {
            ".name": "pg_explicit_off",
            ".type": "balancer",
            enabled: "1",
            balancer_type: "priority",
            name: "Explicit off",
            pick_fastest: "0"
        },
        {
            ".name": "pg_explicit_on",
            ".type": "balancer",
            enabled: "1",
            balancer_type: "priority",
            name: "Explicit on",
            pick_fastest: "1"
        }
    ],
    section: [
        {
            ".name": "main",
            ".type": "section",
            enabled: "1",
            action: "connection",
            balancer_refs: [ "pg_fast", "pg_explicit_off", "pg_explicit_on" ]
        }
    ]
};

connections.set_item_sections_from_data(fixture);

check(connections.priority_group_pick_fastest(fixture.section[0], "pg_fast") === true,
    "a group that says nothing must pick the fastest node");
check(connections.priority_group_pick_fastest(fixture.section[0], "pg_explicit_off") === false,
    "an explicit pick_fastest=0 must be kept");
check(connections.priority_group_pick_fastest(fixture.section[0], "pg_explicit_on") === true,
    "an explicit pick_fastest=1 must be kept");

print("ok");
UCODE
)"

[ "$out" = "ok" ] || fail "priority tier selection is broken: $out"

# 2. The runtime picks the lowest delay of the tier, not the first in the
#    list. The fixture drives the real decision function.
PRIORITY_UC="$TACHYON_LIB/tachyon_core/priority.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/group.json" <<'JSON'
{
  "tag": "pg",
  "pick_fastest": true,
  "levels": [
    { "id": "top", "outbounds": [ "slow", "fast", "middle" ] }
  ]
}
JSON
cat >"$WORK_DIR/latency.json" <<'JSON'
{ "slow": 900, "fast": 20, "middle": 300 }
JSON
selected="$(ucode -L "$TACHYON_LIB" "$PRIORITY_UC" select-fixture \
  "$WORK_DIR/group.json" "$WORK_DIR/latency.json" 0 0)"
printf '%s\n' "$selected" | grep -Fq '"tag": "fast"' ||
  fail "the fastest node of the tier must win, got: $selected"

# 2b. The order the nodes are tried in follows the measured delay, so the
#     first living node of the tier is the fastest one. A node that the core
#     could not reach last time goes to the back, so the tier is entered on
#     the next node instead of a dead one.
cat >"$WORK_DIR/order-group.json" <<'JSON'
{
  "tag": "pg",
  "pick_fastest": true,
  "levels": [
    { "id": "top", "outbounds": [ "dead-first", "alive-second" ] }
  ]
}
JSON
cat >"$WORK_DIR/order-latency.json" <<'JSON'
{ "dead-first": -1, "alive-second": 400 }
JSON
ordered="$(ucode -L "$TACHYON_LIB" "$PRIORITY_UC" select-fixture \
  "$WORK_DIR/order-group.json" "$WORK_DIR/order-latency.json" 0 0)"
printf '%s\n' "$ordered" | grep -Fq '"tag": "alive-second"' ||
  fail "the tier must fall through to the next living node, got: $ordered"

# 3. A dead node in the tier must not make the tier look dead: the first
#    living node of the tier wins even when it is not the fastest measured.
cat >"$WORK_DIR/mixed-latency.json" <<'JSON'
{ "slow": 900, "fast": -1, "middle": 300 }
JSON
mixed="$(ucode -L "$TACHYON_LIB" "$PRIORITY_UC" select-fixture \
  "$WORK_DIR/group.json" "$WORK_DIR/mixed-latency.json" 0 0)"
printf '%s\n' "$mixed" | grep -Eq '"tag": "(slow|middle)"' ||
  fail "a dead node must not win the tier, got: $mixed"

printf 'Priority tier picks the fastest node passed\n'
