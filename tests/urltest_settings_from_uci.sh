#!/usr/bin/env bash
# Invariant: urltest_settings_for() must return the URLTest settings that a
# `config urltest` child declares for a rule section, because build_steer_spec()
# copies them onto the section as steer_urltest_settings and the generator turns
# them into spec v2 `pick: latency` group interval / tolerance / url /
# idle_timeout.
#
# This used to return [] for every section that actually HAD a matching child:
# the collector built its entries with the JS method form found.push(...), which
# ucode rejects at runtime ("left-hand side is not a function"), and the
# surrounding catch (e) {} swallowed the exception. The generator therefore
# never saw the operator's interval, tolerance, testing URL or idle timeout and
# shipped hardcoded defaults on the steer engine instead.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi

LIB_UC="$TACHYON_LIB/service/engine_runtime_lib.uc"
[ -f "$LIB_UC" ] || fail "missing $LIB_UC"

# ucode arrays have no methods, so any .push( style call is dead on arrival.
if grep -n '\.push(' "$LIB_UC"; then
  fail "engine_runtime_lib.uc calls the JS method form .push() on a ucode array; use push(array, value)"
fi

# Mock uci module: one urltest child naming rule section "fast" with every
# setting declared, one naming "slow" with only its parent, so both the match
# path and the defaults path run.
cat >"$WORK_DIR/uci.uc" <<'UCODE'
let state = {
    tachyon: {
        g_fast: {
            ".name": "g_fast",
            ".type": "urltest",
            section: "fast",
            name: "Fastest",
            check_interval: "1m",
            tolerance: "25",
            testing_url: "https://example.com/204",
            idle_timeout: "10m"
        },
        g_slow: {
            ".name": "g_slow",
            ".type": "urltest",
            section: "slow",
            name: "Backup"
        }
    }
};

function cursor() {
    return {
        foreach: function(package_name, type_name, callback) {
            let pkg = state["" + package_name] || {};
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

ucode -L "$WORK_DIR" -L "$TACHYON_LIB" -e '
let ertl = require("service.engine_runtime_lib");

function assert(val, msg) {
    if (!val) {
        warn("Assertion failed: " + msg + "\n");
        exit(1);
    }
}

// A section with a matching child must yield that child, all five settings
// carried through. Before the fix the match threw inside foreach, the catch
// swallowed it, and this came back empty.
let got = ertl.urltest_settings_for("fast");
assert(length(got) == 1,
    "urltest_settings_for(\"fast\") returned " + length(got) +
    " group(s), expected 1 - the collector dropped the match");
assert(got[0].name == "Fastest", "group name must survive");
assert(got[0].check_interval == "1m", "check_interval must survive");
assert(got[0].tolerance == "25", "tolerance must survive");
assert(got[0].testing_url == "https://example.com/204", "testing_url must survive");
assert(got[0].idle_timeout == "10m", "idle_timeout must survive");

// A child that declares only its parent still yields documented defaults.
let bare = ertl.urltest_settings_for("slow");
assert(length(bare) == 1, "section \"slow\" must still be found");
assert(bare[0].name == "Backup", "child name must survive");
assert(bare[0].check_interval == "3m", "check_interval default is 3m");
assert(bare[0].tolerance == "50", "tolerance default is 50");
assert(bare[0].testing_url == "https://www.gstatic.com/generate_204", "testing_url default");
assert(bare[0].idle_timeout == "", "idle_timeout default is empty");

// No matching child, and the empty-name guard, must both return [] without
// throwing: the foreach is wrapped in try/catch on purpose.
assert(length(ertl.urltest_settings_for("missing")) == 0,
    "a section with no urltest child must yield an empty list");
assert(length(ertl.urltest_settings_for("")) == 0,
    "an empty section name must yield an empty list");

printf("urltest_settings_for assertions passed\n");
'

printf 'urltest settings from UCI checks passed\n'
