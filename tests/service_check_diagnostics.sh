#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
SERVICE_CHECK_UC="$TACHYON_LIB/diagnostics/service_check.uc"

# 1. Test get-targets
targets_json="$(ucode -L "$TACHYON_LIB" "$SERVICE_CHECK_UC" get-targets)"
[ -n "$targets_json" ] || fail "service_check get-targets returned empty output"

# 2. Test get-targets with all mode
targets_all_json="$(ucode -L "$TACHYON_LIB" "$SERVICE_CHECK_UC" get-targets all)"
[ -n "$targets_all_json" ] || fail "service_check get-targets all returned empty output"

# 4. Test get-profiles
profiles_json="$(ucode -L "$TACHYON_LIB" "$SERVICE_CHECK_UC" get-profiles)"
[ -n "$profiles_json" ] || fail "service_check get-profiles returned empty output"

# 5. Test custom domain inline comment stripping, invalid domain filtering, and gemini_geo skipping without API key
TEST_UCI_STATE="$(mktemp)"
trap 'rm -f "$TEST_UCI_STATE"' EXIT
cat >"$TEST_UCI_STATE" <<'EOF'
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.custom_sec=section
tachyon.custom_sec.enabled=1
tachyon.custom_sec.connection_type=proxy
tachyon.custom_sec.action=connection
tachyon.custom_sec.community_lists=gemini
tachyon.custom_sec.user_domains_text=clean-target.example.com # inline comment
tachyon.custom_sec.domain_text=slash-target.example.org // trailing comment
tachyon.custom_sec.domain_suffix_text=# comment only line
tachyon.custom_sec.domain=not a valid domain!
EOF

filtered_targets_json="$(TACHYON_UCI_STATE_FILE="$TEST_UCI_STATE" ucode -L "$TACHYON_LIB" "$SERVICE_CHECK_UC" get-targets)"
ucode -e '
let data = json(ARGV[0]);
let targets = type(data) == "array" ? data : [];
let found_clean = false;
let found_slash = false;
for (let t in targets) {
    let d = t.domain || "";
    if (d == "clean-target.example.com") found_clean = true;
    if (d == "slash-target.example.org") found_slash = true;
    if (index(d, "#") >= 0 || index(d, " ") >= 0 || index(d, "/") >= 0 || index(d, "!") >= 0)
        die("unstripped comment or invalid domain leaked into targets: " + d + "\n");
    if (t.kind == "gemini_geo")
        die("gemini_geo should be skipped when no AI API key is configured\n");
}
if (!found_clean || !found_slash)
    die("valid custom domains with inline comments were not extracted\n");
' "$filtered_targets_json" || fail "service_check custom domain comment stripping and gemini_geo gating failed"

printf 'service check diagnostics passed\n'
