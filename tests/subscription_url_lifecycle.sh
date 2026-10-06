#!/usr/bin/env bash
# Subscription URL lifecycle: add, remove, and per-URL enable/disable.
#
# Two separate defects hide here.
#
# Removal has to reach everywhere at once. A subscription URL is a
# `config subscription_url` section whose identity is its `url`, and every
# consumer addresses it by *position*: source_id() is "<section>-subscription-<n>".
# That makes the numbering load-bearing. A disabled or removed source must keep
# its slot - counting only the live ones shifts every later source by one, and
# the cache file of one source then reads as another's, which is silent.
#
# Enable/disable is not the same as "do not auto-update". subscription_update_enabled
# only gates the periodic refresh; the source is still downloaded on prepare and
# still lands in the generated config. Disabling a URL has to keep it out of the
# download, the cache and the outbounds.
#
# Driven from a fixture config, not from greps.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
[ -f "$LIB_DIR/config/connections.uc" ] || fail "config/connections.uc not found"

# A mock uci cursor, the same seam tests/subscription_section_order.sh uses:
# config.connections reads the child sections through the cursor, not from a
# JSON fixture, so the config has to arrive that way.
cat >"$WORK_DIR/uci.uc" <<'UCODE'
let state = {
    tachyon: {
        sec1: { ".name": "sec1", ".type": "section", action: "connection", enabled: "1" },
        other_section: { ".name": "other_section", ".type": "section", action: "connection" },
        s1: { ".name": "s1", ".type": "subscription_url", section: "sec1",
              url: "https://one.example/sub", order: "0", enabled: "1" },
        s2: { ".name": "s2", ".type": "subscription_url", section: "sec1",
              url: "https://two.example/sub", order: "1", enabled: "0" },
        s3: { ".name": "s3", ".type": "subscription_url", section: "sec1",
              url: "https://three.example/sub", order: "2" },
        alien: { ".name": "alien", ".type": "subscription_url", section: "other_section",
                 url: "https://not-mine.example/sub", order: "3", enabled: "0" }
    }
};

function cursor() {
    return {
        load: function(_pkg) { return true; },
        foreach: function(pkg_name, type_name, callback) {
            let pkg = state["" + pkg_name] || {};
            for (let name in pkg) {
                let section = pkg[name];
                if (section && section[".type"] == type_name)
                    callback(section);
            }
        }
    };
}

return { cursor };
UCODE

cat >"$WORK_DIR/probe.uc" <<'UCODE'
let connections = require("config.connections");
let cursor = require("uci").cursor();

connections.set_item_sections_from_cursor(cursor, "tachyon");

let sec = { ".name": "sec1", action: "connection" };
let urls = connections.subscription_urls(sec);

for (let u in urls)
    printf("url=%s enabled=%s update=%s\n", u,
        connections.subscription_url_enabled(sec, u) ? "y" : "n",
        connections.subscription_update_enabled(sec, u) ? "y" : "n");

printf("total=%d\n", length(urls));
UCODE

out="$(ucode -L "$WORK_DIR" -L "$LIB_DIR" "$WORK_DIR/probe.uc" 2>&1)" \
  || fail "could not read the subscription URLs: $out"

# ─── the flag is read, and it is not the auto-update flag ────────────────────
grep -q '^url=https://one.example/sub enabled=y update=y$' <<< "$out" \
  || fail "an explicitly enabled URL must read as enabled: $out"
grep -q '^url=https://two.example/sub enabled=n' <<< "$out" \
  || fail "enabled=0 did not disable the source: $out"
grep -q '^url=https://three.example/sub enabled=y' <<< "$out" \
  || fail "a URL written before the flag existed must default to enabled, or every existing configuration would silently lose its subscriptions: $out"

# A disabled source keeps its own update flag - they are different decisions and
# conflating them is how "I turned off auto-update and my nodes vanished" happens.
grep -q '^url=https://two.example/sub enabled=n update=y$' <<< "$out" \
  || fail "disabling a source also changed its auto-update setting: $out"

# ─── belonging to another section is not a way in ───────────────────────────
grep -q 'not-mine' <<< "$out" \
  && fail "a subscription URL of another section leaked into this one: $out"
grep -q '^total=3$' <<< "$out" \
  || fail "expected exactly this section's three URLs: $out"

# ─── a toggle has to change the signature, or nothing rebuilds ───────────────
# Checked in the source rather than at runtime: service/state.uc is CLI-only, so
# subscription_urls_signature cannot be called from a test without running a CLI
# and exiting the interpreter. The inputs it reads are verified above.
sig_body="$(sed -n '/^function subscription_urls_signature/,/^}/p' "$LIB_DIR/service/state.uc")"
grep -q 'enabled: connections.subscription_url_enabled(section, entry)' <<< "$sig_body"   || fail "the enabled flag is missing from subscription_urls_signature, so toggling a URL would leave the signature identical and never rebuild the config"

# ─── the position is load-bearing and must not shift ─────────────────────────
# source_id is "<section>-subscription-<n>". The reader side increments for every
# URL and only then skips the disabled one, so slot 2 belongs to the disabled URL
# and slot 3 to the third. A reader that skipped before counting would hand slot
# 2 to the third URL.
# The ordering itself: in each loop the counter must advance before the skip,
# otherwise a disabled source loses its slot and every later source is read
# against the wrong cache file.
# Compared by line number inside the function body: the loop must advance the
# counter before it can continue, or a disabled source loses its slot.
check_order() {
    local rel="$1" fn="$2" body inc cont
    body="$(sed -n "/^function $fn(/,/^}/p" "$LIB_DIR/$rel")" || return 1
    [ -n "$body" ] || { echo "function $fn not found"; return 1; }

    # Start counting at the loop over the URL list, so a counter elsewhere in the
    # function cannot be mistaken for the one inside the loop.
    local loop_line
    loop_line="$(printf '%s\n' "$body" | grep -n 'for (let [a-z_]* in \(connections\.subscription_urls(section)\|urls\))' | head -1 | cut -d: -f1)"
    [ -n "$loop_line" ] || { echo "loop over the URL list not found"; return 1; }

    inc="$(printf '%s\n' "$body" | tail -n "+$loop_line" | grep -n -m1 '^\s*\(total\|index\)++;' | cut -d: -f1)"
    cont="$(printf '%s\n' "$body" | tail -n "+$loop_line" | grep -n -m1 'continue;' | cut -d: -f1)"
    [ -n "$inc" ] || { echo "counter not incremented inside the loop"; return 1; }
    if [ -n "$cont" ] && [ "$cont" -lt "$inc" ]; then
        echo "continue precedes the counter increment, which renumbers sources"
        return 1
    fi
    return 0
}

for spec in "subscription/cache.uc prepare_subscription_cache_section" \
            "subscription/cache.uc subscription_update_section" \
            "steer/section_cache.uc build_section_cache"; do
    set -- $spec
    reason="$(check_order "$1" "$2")" || fail "$1/$2: $reason"
done

printf 'fault: subscription URL lifecycle checks passed
'
