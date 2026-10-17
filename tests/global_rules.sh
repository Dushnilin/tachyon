#!/usr/bin/env bash
# A section may claim one of its own condition values as global: the entry lives
# on the owner as list global_rules '<kind>:<value>' and reserves that value
# against every other section.
#
# Two invariants are worth a test each, because both are invisible until they
# break:
#   * a claim the owner no longer uses is inert. Without that, deleting one
#     condition from a section would block every apply afterwards, and the stale
#     claim would keep starving other sections of a value nobody uses;
#   * a value another section actually claims is rejected with both section
#     names. Without it two sections silently share one community list with two
#     different actions and the first match wins by row order.
#
# Every rejection below passes on its own when validate_global_rules() is not
# wired into validate_runtime_config(), which is exactly the failure mode this
# file guards.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR="$TACHYON_LIB/config/validator.uc"
[ -f "$VALIDATOR" ] || fail "config/validator.uc not found at $VALIDATOR"

# context_override_value() runs every value through as_string(), so the list has
# to arrive as the space-separated string core/constants.uc actually stores.
CTX='{"community_services":"youtube telegram"}'

# --- 1. claim syntax lives behind the module boundary ----------------------
claim="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let c = require("config.connections");
let simple = c.global_rule_claim("community_lists:youtube");
let url = c.global_rule_claim("rule_set:https://example.com/a.srs");
if (type(c.GLOBAL_RULE_OPTIONS) != "object")
    print("options-missing");
else if (simple == null || simple.kind != "community_lists" || simple.value != "youtube")
    print("simple-broken");
else if (url == null || url.value != "https://example.com/a.srs")
    print("url-broken");
else if (c.global_rule_claim("bogus:value") != null)
    print("unknown-kind-accepted");
else if (c.global_rule_claim("no-colon") != null)
    print("missing-colon-accepted");
else
    print("ok");
' 2>/dev/null)" || true

[ "$claim" = "ok" ] || fail "global_rule_claim parsing is broken: $claim"

# --- 2. condition values are read the same way on both sides ---------------
# The domain kind lives in a textarea, not a UCI list: newline/comma separated
# free text. Reading it as one blob would never match a claim.
values="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let c = require("config.connections");
let s = { ".name": "s", ".type": "section", "domain": "full:example.com\nfoo.com" };
let v = c.condition_values(s, "domain");
if (v == null)
    print("null");
else if (v["full:example.com"] == true && v["foo.com"] == true && length(keys(v)) == 2)
    print("ok");
else
    print(sprintf("%J", keys(v)));
' 2>/dev/null)" || true

[ "$values" = "ok" ] || fail "condition_values(domain) must split textarea text, got: $values"

# --- 3. runtime validation across sections ---------------------------------
write_fixture() {
  local path="$1" sections="$2"
  cat >"$path" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": $sections
}
JSON
}

assert_accepts() {
  local label="$1" json="$2"
  local path="$WORK_DIR/fixture.json"
  write_fixture "$path" "$json"
  if ! TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR" \
      validate-runtime-fixture "$path" "$CTX" >"$WORK_DIR/out" 2>&1; then
    fail "$label must be accepted, but init.d would abort: $(tail -3 "$WORK_DIR/out" | tr '\n' ' ')"
  fi
}

assert_rejects() {
  local label="$1" json="$2"
  local path="$WORK_DIR/fixture.json"
  write_fixture "$path" "$json"
  if TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR" \
      validate-runtime-fixture "$path" "$CTX" >"$WORK_DIR/out" 2>&1; then
    fail "$label must be rejected, but init.d would happily start: $(tail -3 "$WORK_DIR/out" | tr '\n' ' ')"
  fi
  # Every message this feature emits says "global rule". Requiring it keeps a
  # fixture that happens to be invalid for an unrelated reason from passing as
  # if exclusivity had been enforced.
  grep -qi "global rule" "$WORK_DIR/out" ||
    fail "$label was rejected for the wrong reason: $(tail -3 "$WORK_DIR/out" | tr '\n' ' ')"
}

# A config without a single claim - everything shipped before this feature -
# must keep validating untouched.
assert_accepts "a config with no global rules" '[
  {
    ".name": "plain", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"plain-out\"}" ],
    "community_lists": [ "telegram" ]
  }
]'

# The owner keeps the value, nobody else has it.
assert_accepts "an owner section alone with its claim" '[
  {
    ".name": "owner", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"owner-out\"}" ],
    "community_lists": [ "youtube", "telegram" ],
    "global_rules": [ "community_lists:youtube" ]
  },
  {
    ".name": "other", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"other-out\"}" ],
    "community_lists": [ "telegram" ]
  }
]'

# The whole point: a second section still carrying the claimed value is a
# conflict, and the message has to name both sections so it can be fixed.
assert_rejects "a claimed value still used by another section" '[
  {
    ".name": "owner", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"owner-out\"}" ],
    "community_lists": [ "youtube" ],
    "global_rules": [ "community_lists:youtube" ]
  },
  {
    ".name": "other", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"other-out\"}" ],
    "community_lists": [ "youtube" ]
  }
]'

# A claim left behind by a condition that was later removed must not hold the
# value: nobody uses it, so the other section keeps it and the apply stays green.
assert_accepts "a stale claim that its owner no longer uses" '[
  {
    ".name": "owner", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"owner-out\"}" ],
    "community_lists": [ "telegram" ],
    "global_rules": [ "community_lists:youtube" ]
  },
  {
    ".name": "other", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"other-out\"}" ],
    "community_lists": [ "youtube" ]
  }
]'

# An entry that is not '<option>:<value>' carries an intent nobody can honour;
# silently ignoring it would leave the user believing they reserved something.
assert_rejects "a malformed claim" '[
  {
    ".name": "owner", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"owner-out\"}" ],
    "community_lists": [ "youtube" ],
    "global_rules": [ "community_lists" ]
  }
]'

# Two owners for one value is the same conflict viewed from the other side.
assert_rejects "two sections claiming the same value" '[
  {
    ".name": "first", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"first-out\"}" ],
    "community_lists": [ "youtube" ],
    "global_rules": [ "community_lists:youtube" ]
  },
  {
    ".name": "second", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"second-out\"}" ],
    "community_lists": [ "youtube" ],
    "global_rules": [ "community_lists:youtube" ]
  }
]'

# The same exclusivity has to hold for a free-text condition, not just for the
# catalog pickers - domains are stored as a textarea on one side and a list on
# the other.
assert_rejects "a claimed domain still typed into another section" '[
  {
    ".name": "owner", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"owner-out\"}" ],
    "domain": "example.com\nother.example",
    "global_rules": [ "domain:example.com" ]
  },
  {
    ".name": "other", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"other-out\"}" ],
    "domain_suffix": [ "example.com" ]
  }
]'

printf 'OK: global rule claims reserve a value against other sections\n'
