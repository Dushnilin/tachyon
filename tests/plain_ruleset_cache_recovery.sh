#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
export CASE_DIR="$WORK_DIR"
cat >"$WORK_DIR/test.uc" <<'UCODE'
let fs = require("fs");
let folder = getenv("CASE_DIR");
let runtime_ruleset_folder = folder;
let downloads = 0;
let compiled = 0;
let download_ok = true;
let ctx = { runtime_ruleset_folder: folder };
let cache = folder + "/inline-custom-fixture-ruleset.srs";
let runtime_rulesets = {
    kind_from_reference_hint: function(ref) { return "domains"; },
    is_community: function(ref) { return false; },
    is_plain_list_reference: function(ref) { return true; },
    hash12: function(ref) { return "fixture"; },
    file_extension: function(ref) { return "lst"; },
    is_valid_srs_file: function(path) { return index(fs.readfile(path) || "", "SRS") == 0; },
    is_adoptable_srs_file: function(path) { return fs.readfile(path) == "SRS-valid"; },
    ensure_empty_srs_stub: function(path) {
        // Match the real helper's preserve-existing behavior.
        if (index(fs.readfile(path) || "", "SRS") != 0) fs.writefile(path, "SRS-stub");
        return true;
    }
};
let common = {
    ensure_dir: function(path) {},
    copy_file: function(src, dst) { return true; },
    command_success: function(cmd) { return true; },
    command_success_from_args: function(args) {
        downloads++;
        if (download_ok) fs.writefile(args[length(args)-1], "example.test\n");
        return download_ok;
    }
};
let source_rulesets = { compile_plain_list: function(input, srs, json_path) {
    compiled++;
    if (fs.stat(input) == null) die("missing plain source\n");
    fs.writefile(srs, "SRS-valid");
    return { format: "binary", path: srs, kind: "domains" };
} };
let ruleset_registered = function(config, tag) { return false; };
let remote_custom_ruleset_tag = function(ref) { return "unused"; };
let plain_ruleset_kind = function(a,b,c,d) { return "domains"; };
let apply_download_transport = function(a,b,c) {};
let remote_ruleset_update_interval = function() { return "1h"; };
let helpers = {
    file_is_usable: function(path, minimum) {
        let st = fs.stat(path);
        return st != null && st.type == "file" && st.size >= minimum;
    }
};
UCODE
sed -n '/^function ensure_custom_ruleset(/,/^}/p' "$TACHYON_LIB/tachyon_core/generator_routes.uc" >>"$WORK_DIR/test.uc"
cat >>"$WORK_DIR/test.uc" <<'UCODE'
for (let old in ["SRS-stub", "SRS-broken"]) {
    fs.writefile(cache, old);
    let config = { route: { rule_set: [] } };
    let before = downloads;
    ensure_custom_ruleset(config, "https://example.test/recovery.lst");
    if (downloads != before + 1 || fs.readfile(cache) != "SRS-valid")
        die("stub/broken cache blocked recovery\n");
}
if (compiled != 2) die("successfully empty HTTP body was not compiled\n");
download_ok = false;
fs.writefile(cache, "SRS-broken");
ensure_custom_ruleset({ route: { rule_set: [] } }, "https://example.test/recovery.lst");
if (fs.readfile(cache) != "SRS-stub") die("broken file retained as offline fallback\n");
fs.writefile(cache, "SRS-valid");
let before = downloads;
ensure_custom_ruleset({ route: { rule_set: [] } }, "https://example.test/recovery.lst");
if (downloads != before) die("valid cache unnecessarily downloaded\n");
print("plain ruleset cache recovery passed\n");
UCODE
ucode -S "$WORK_DIR/test.uc"
