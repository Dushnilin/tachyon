#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
# Load the actual updater functions without executing its CLI dispatcher. Only
# external IO is replaced: preset available, subnet download fails, no cache.
awk '/^let mode = ARGV\[0\]/{exit} {print}' \
  "$TACHYON_LIB/components/updates.uc" >"$WORK_DIR/probe.uc"
cat >>"$WORK_DIR/probe.uc" <<'UC'
import_community_srs_file = function() { return true; };
download_to_file = function() { return false; };
file_exists_value = function() { return false; };
ensure_dir = function() { return true; };
let fallback_files = {};
write_file = function(path, content) { fallback_files[path] = content; return true; };
let fallback_calls = [];
nft_module_success = function(args) { push(fallback_calls, args); return true; };
list_nft_batch = "/tmp/test-telegram-batch";
let fallback_ok = import_builtin_subnets_from_rule({
    ".name": "direct", enabled: "1", action: "bypass", community_lists: ["telegram"]
}, {});
if (!fallback_ok || length(fallback_calls) != 1)
    die("Telegram fallback must be queued in the replacement transaction\n");
let fallback_content = fallback_files[fallback_calls[0][3]] || "";
let fallback_ip = require("core.ip");
if (index(fallback_content, fallback_ip.DEFAULT_TELEGRAM_SUBNETS[0]) < 0 ||
    index(fallback_content, fallback_ip.DEFAULT_TELEGRAM_SUBNETS6[0]) < 0)
    die("Fallback nft input must contain both IPv4 and IPv6 Telegram ranges\n");
print("list update Telegram fallback tests passed\n");
UC
ucode -L "$TACHYON_LIB" "$WORK_DIR/probe.uc"
