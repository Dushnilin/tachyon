#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
SB_UC="$TACHYON_LIB/service/support_bundle.uc"
API_UC="$TACHYON_LIB/service/api.uc"
AGENT_API_UC="$TACHYON_LIB/service/agent_api.uc"
AGENT_MCP_UC="$TACHYON_LIB/service/agent_mcp.uc"
TG_COMMANDS_UC="$TACHYON_LIB/service/telegram/commands.uc"
BIN_TACHYON="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected to contain '$needle', got: $haystack" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) fail "$label: expected NOT to contain '$needle', but found it" ;;
    *) ;;
  esac
}

# --- 1. Static Contract Inspections ---

[ -f "$SB_UC" ] || fail "service/support_bundle.uc must exist"

grep -Fq 'function create_bundle(' "$SB_UC" ||
  fail "support_bundle.uc must define create_bundle"
grep -Fq 'function stage_bundle(' "$SB_UC" ||
  fail "support_bundle.uc must define stage_bundle"
grep -Fq 'function collect_metadata(' "$SB_UC" ||
  fail "support_bundle.uc must define collect_metadata"
grep -Fq 'function collect_versions(' "$SB_UC" ||
  fail "support_bundle.uc must define collect_versions"
grep -Fq 'function collect_service_status(' "$SB_UC" ||
  fail "support_bundle.uc must define collect_service_status"
grep -Fq 'function collect_events_and_jobs(' "$SB_UC" ||
  fail "support_bundle.uc must define collect_events_and_jobs"
grep -Fq 'function collect_process_and_fd_stats(' "$SB_UC" ||
  fail "support_bundle.uc must define collect_process_and_fd_stats"
grep -Fq 'function redact_string(' "$SB_UC" ||
  fail "support_bundle.uc must define redact_string"
grep -Fq 'function redact_object(' "$SB_UC" ||
  fail "support_bundle.uc must define redact_object"
grep -Fq 'function sanitize_uci_text(' "$SB_UC" ||
  fail "support_bundle.uc must define sanitize_uci_text"
grep -Fq 'function selftest()' "$SB_UC" ||
  fail "support_bundle.uc must define selftest"
grep -Fq 'function set_test_overrides(' "$SB_UC" ||
  fail "support_bundle.uc must define set_test_overrides"

# Wiring in /usr/bin/tachyon
grep -Fq 'support_bundle: [ "service/support_bundle.uc", "create", 3 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map support_bundle in command_spec"
grep -Fq '"support-bundle": [ "service/support_bundle.uc", "create", 3 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map support-bundle in command_spec"
grep -Fq 'command == "support_bundle" || command == "support-bundle"' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must dispatch support_bundle in main"
grep -Fq 'support_bundle [path]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon show_help must document support_bundle"

# Wiring in service/api.uc
grep -Fq 'create_support_bundle' "$API_UC" ||
  fail "service/api.uc must export create_support_bundle"

# Wiring in service/agent_api.uc
grep -Fq 'handle_support_bundle' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must define handle_support_bundle"
grep -Fq 'tachyon_support_bundle' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must register tachyon_support_bundle tool"
grep -Fq '/support-bundle' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must route /support-bundle endpoint"

# Wiring in service/agent_mcp.uc
grep -Fq 'tachyon_support_bundle' "$AGENT_MCP_UC" ||
  fail "service/agent_mcp.uc must register tachyon_support_bundle tool"
grep -Fq 'execute_support_bundle' "$AGENT_MCP_UC" ||
  fail "service/agent_mcp.uc must define execute_support_bundle"

# Wiring in service/telegram/commands.uc
grep -Fq 'require("service.support_bundle")' "$TG_COMMANDS_UC" ||
  fail "telegram/commands.uc must delegate to service.support_bundle"

# --- 2. Ucode Syntax and Forward Reference Checks ---

if command -v node >/dev/null 2>&1 && [ -f "$ROOT_DIR/tests/lib/ucode_forward_refs.js" ]; then
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$SB_UC" ||
    fail "forward reference lint failed for support_bundle.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$API_UC" ||
    fail "forward reference lint failed for api.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$AGENT_API_UC" ||
    fail "forward reference lint failed for agent_api.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$AGENT_MCP_UC" ||
    fail "forward reference lint failed for agent_mcp.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$TG_COMMANDS_UC" ||
    fail "forward reference lint failed for telegram/commands.uc"
fi

if command -v ucode >/dev/null 2>&1; then
  ucode -c "$SB_UC" || fail "ucode -c failed for support_bundle.uc"
  ucode -S -c "$SB_UC" || fail "ucode -S -c failed for support_bundle.uc"

  # --- 3. Built-in Selftest ---
  selftest_output=$(ucode -L "$TACHYON_LIB" -- "$SB_UC" selftest)
  assert_contains "$selftest_output" "passed" "selftest output"
  assert_contains "$selftest_output" "0 failed" "selftest zero failures"

  # --- 4. CLI Execution Checks ---

  # 4.1 Plain text status / creation
  tmp_test_bundle="/tmp/test_support_bundle_cli_${RANDOM}_$$.tar.gz"
  rm -f "$tmp_test_bundle"

  cli_text=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -- "$BIN_TACHYON" support_bundle "$tmp_test_bundle")
  assert_contains "$cli_text" "TACHYON SUPPORT BUNDLE GENERATED" "CLI plain text banner"
  assert_contains "$cli_text" "Redaction:" "CLI plain text redaction notice"
  [ -f "$tmp_test_bundle" ] || fail "CLI support_bundle should have created archive file"
  rm -f "$tmp_test_bundle"

  # 4.2 JSON output
  tmp_test_bundle2="/tmp/test_support_bundle_json_${RANDOM}_$$.tar.gz"
  rm -f "$tmp_test_bundle2"

  cli_json=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -- "$BIN_TACHYON" support_bundle "$tmp_test_bundle2" --json)
  assert_contains "$cli_json" '"ok": true' "CLI JSON ok key"
  assert_contains "$cli_json" '"bundle_path":' "CLI JSON bundle_path key"
  assert_contains "$cli_json" '"sha256":' "CLI JSON sha256 key"
  [ -f "$tmp_test_bundle2" ] || fail "CLI JSON support_bundle should have created archive file"
  rm -f "$tmp_test_bundle2"

  # --- 5. Secret Redaction & Archive Integrity Sandbox Verification ---

  TEST_TMP_ROOT="/tmp/test_sb_sandbox_${RANDOM}_$$"
  export TEST_TMP_ROOT

  sandbox_result=$(ucode -L "$TACHYON_LIB" -e '
    let fs = require("fs");
    let sb = require("service.support_bundle");

    let tmp_root = getenv("TEST_TMP_ROOT") || ("/tmp/test_sb_sandbox_" + sprintf("%d", time()));
    let mock_cfg_dir = tmp_root + "/config";
    let mock_cfg_file = mock_cfg_dir + "/tachyon";
    let extract_dir = tmp_root + "/extracted";
    let bundle_file = tmp_root + "/diagnostic_bundle.tar.gz";

    system("mkdir -p " + mock_cfg_dir + " " + extract_dir);

    // Write a mock UCI config loaded with sensitive credentials
    let secret_bot_token = "987654321:XYZ-abcdef_1234567890ABCDEFGH1234";
    let secret_chat_id = "1122334455";
    let secret_vless_uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    let secret_bearer = "secret_agent_token_long_random_value_xyz";
    let secret_pk = "MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwgg";

    let mock_uci_content =
      "config settings '\''settings'\''\n" +
      "    option telegram_bot_token '\''" + secret_bot_token + "'\''\n" +
      "    option agent_api_token '\''" + secret_bearer + "'\''\n" +
      "    list allowed_chats '\''" + secret_chat_id + "'\''\n" +
      "    option private_key '\''" + secret_pk + "'\''\n" +
      "    option enabled '\''1'\''\n\n" +
      "config server '\''srv1'\''\n" +
      "    option server '\''vless://" + secret_vless_uuid + "@example.com:443'\''\n" +
      "    option label '\''Test VLESS Server'\''\n";

    fs.writefile(mock_cfg_file, mock_uci_content);

    // Apply test override so support_bundle reads our mock config
    sb.set_test_overrides(tmp_root + "/stage", mock_cfg_file);

    // Create the bundle
    let b_res = sb.create_bundle(bundle_file);
    if (!b_res.ok) {
      print("FAIL: create_bundle failed: " + (b_res.error || "unknown") + "\n");
      exit(1);
    }

    if (fs.stat(bundle_file) == null) {
      print("FAIL: archive file was not created on disk\n");
      exit(1);
    }

    // Extract archive
    system("tar -xzf " + bundle_file + " -C " + extract_dir);

    // Verify sha256 checksums inside archive
    let chk_res = system("cd " + extract_dir + " && sha256sum -c checksums.sha256 > /dev/null 2>&1");
    if (chk_res != 0) {
      print("FAIL: embedded checksums.sha256 failed verification\n");
      exit(1);
    }

    // Read extracted tachyon.uci
    let ext_uci = fs.readfile(extract_dir + "/config_sanitized/tachyon.uci");
    if (!ext_uci) {
      print("FAIL: config_sanitized/tachyon.uci missing in bundle\n");
      exit(1);
    }

    // Verify zero leakage of secrets
    if (index(ext_uci, secret_bot_token) >= 0) {
      print("FAIL: Telegram bot token LEAKED in bundle\n");
      exit(1);
    }
    if (index(ext_uci, secret_bearer) >= 0) {
      print("FAIL: Agent Bearer token LEAKED in bundle\n");
      exit(1);
    }
    if (index(ext_uci, secret_vless_uuid) >= 0) {
      print("FAIL: VLESS UUID LEAKED in bundle\n");
      exit(1);
    }
    if (index(ext_uci, secret_pk) >= 0) {
      print("FAIL: Private key LEAKED in bundle\n");
      exit(1);
    }

    // Verify redaction markers present
    if (index(ext_uci, "[REDACTED]") < 0) {
      print("FAIL: Expected [REDACTED] marker missing in sanitized UCI\n");
      exit(1);
    }

    // Verify metadata.json structure
    let meta = json(fs.readfile(extract_dir + "/metadata.json") || "null");
    if (!meta || !meta.bundle_generated_at || !meta.tachyon_version || !meta.architecture) {
      print("FAIL: metadata.json missing required structured fields\n");
      exit(1);
    }

    // Clean up
    system("rm -rf " + tmp_root);
    sb.set_test_overrides(null, null);

    print("OK: Sandbox redaction & integrity verified\n");
    exit(0);
  ')

  assert_contains "$sandbox_result" "OK: Sandbox redaction & integrity verified" "Sandbox redaction and integrity"
fi

printf 'ALL SUPPORT BUNDLE CHECKS PASSED\n'
