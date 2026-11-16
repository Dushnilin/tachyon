#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

export TMP_TACHYON_CORE_FOLDER="$WORK_DIR" TACHYON_SECTION_CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$WORK_DIR/cache"
cat >"$WORK_DIR/config.json" <<'JSON'
{"outbounds":[{"type":"http","tag":"A"},{"type":"http","tag":"B"},{"type":"http","tag":"C"}]}
JSON
cat >"$WORK_DIR/uci.json" <<'JSON'
{}
JSON
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.json"

# Intercept the delay API request after selection.
cat >"$WORK_DIR/curl" <<'MOCK'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        printf '{"results":{}}\n' > "$2"
        exit 0
    fi
    shift
done
exit 1
MOCK
chmod +x "$WORK_DIR/curl"
export PATH="$WORK_DIR:$PATH"

ucode -L "$TACHYON_LIB" -e '
let c = require("config.connections");
let group = { ".name": "test", include_regex: ["[", "^[AB]$"], exclude_regex: ["^B$"] };
c.set_item_sections_from_data({ outbound_group: [group] });
for (let mode, expected in { include: "A,B", exclude: "A,C", mixed: "A" }) {
    group.filter_mode = mode;
    let result = c.probe_outbound_url("http://test.invalid/204", "test", 800);
    let tags = map(result.results, (entry) => entry.tag);
    if (join(",", tags) != expected)
        die(sprintf("%s: unexpected tags %J\n", mode, tags));
}
' 2>"$WORK_DIR/stderr" || { cat "$WORK_DIR/stderr" >&2; exit 1; }
[ "$(grep -c 'urltest: ignoring invalid regex' "$WORK_DIR/stderr")" -eq 2 ] ||
    fail "expected one warning for the invalid include regex in each applicable mode"
