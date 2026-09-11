#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
DIAGNOSTICS_RUNTIME="$TACHYON_LIB/diagnostics/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

fake_bin="$WORK_DIR/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env sh
case "$*" in
  *'/proxies'|*'/proxies '*)
    printf '%s\n' '{"proxies":{"urltest":{"type":"URLTest"},"node-fail":{"type":"VLESS"}}}'
    ;;
  *'node-fail'*)
    # Simulate a dead node returning Clash timeout error
    printf '%s\n' '{"message":"timeout"}'
    ;;
  *)
    # Simulate an active responsive node
    printf '%s\n' '{"delay":42}'
    ;;
esac
SH
chmod +x "$fake_bin/curl"

uci_state="$WORK_DIR/uci-state.txt"
cat >"$uci_state" <<'EOF'
tachyon.settings=settings
tachyon.settings.latency_test_url=https://latency.example/generate_204
EOF

latency_action_dir="$WORK_DIR/ui-state/latency-actions"
mkdir -p "$latency_action_dir"
latency_state="$latency_action_dir/latency-parallel.json"
printf '%s\n' '{"success":true,"running":true,"kind":"latency","latency_type":"proxy_list","section":"main","tag":"[]","started_at":100}' >"$latency_state"

# Generate 20 tags including 1 failing node
tags_json="$(node -e '
  const tags = [];
  for (let i = 1; i <= 19; i++) tags.push("node-" + i);
  tags.push("node-fail");
  console.log(JSON.stringify(tags));
')"

TACHYON_UCI_STATE_FILE="$uci_state" \
TACHYON_LIB="$TACHYON_LIB" \
TACHYON_UI_LATENCY_ACTION_DIR="$latency_action_dir" \
PATH="$fake_bin:$PATH" \
  ucode -L "$TACHYON_LIB" "$DIAGNOSTICS_RUNTIME" clash-api get_proxy_latencies "$tags_json" 2000 "$latency_state" >/dev/null ||
  true # get_proxy_latencies exits 1 if any node failed, which is expected

JOB_STATE="$latency_state" node - <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.env.JOB_STATE, "utf8"));
if (!value.progress) {
  console.error("progress missing from state");
  process.exit(1);
}
if (value.progress.completed !== 20 || value.progress.total !== 20) {
  console.error(`expected completed=20 total=20, got completed=${value.progress.completed} total=${value.progress.total}`);
  process.exit(1);
}
if (value.progress.failed !== 1) {
  console.error(`expected failed=1, got failed=${value.progress.failed}`);
  process.exit(1);
}
NODE

printf 'Parallel latency test passed\n'
