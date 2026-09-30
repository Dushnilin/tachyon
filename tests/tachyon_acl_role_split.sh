#!/usr/bin/env bash
# rpcd grants file permissions by path and never inspects arguments. While the
# read role held exec on /usr/bin/tachyon, a read-only LuCI session could run
# any subcommand -- emergency_reset, apply_quick_fix, component_install_version,
# snapshot_restore -- because the binary cannot tell the roles apart: a trimmed
# session is the same uid with a smaller ACL and leaves nothing in the
# environment to detect. The split has to be in the file name.
#
# Three things can silently undo this, so all three are pinned:
#   - read regaining exec on the full binary
#   - write losing exec on it, which would break the whole control plane
#   - the read entry point's table drifting from the binary that actually runs
#
# The ACL ships in this package rather than in luci-app-tachyon so that the
# policy and the executable it governs are installed together. The two packages
# update independently, and "new ACL, old backend" means read can exec nothing
# at all, which breaks the UI.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

ROOT="$ROOT_DIR/tachyon"
ACL_JSON="$ROOT/files/usr/share/rpcd/acl.d/luci-app-tachyon.json"
DISPATCHER="$ROOT/files/usr/bin/tachyon"
READ_BIN="$ROOT/files/usr/bin/tachyon-read"

for required in "$ACL_JSON" "$DISPATCHER" "$READ_BIN"; do
  [ -f "$required" ] || fail "missing file: $required"
done

# The ACL must live here, not in the luci package.
[ ! -f "$ROOT_DIR/luci-app-tachyon/root/usr/share/rpcd/acl.d/luci-app-tachyon.json" ] ||
  fail "ACL still ships in luci-app-tachyon; it must move with the binary it governs"

acl_exec() {
  # acl_exec <role> <path> -> "yes" when that role may exec the path
  ucode -e '
    let fs = require("fs");
    let all = json(fs.readfile(ARGV[0]));
    let acl = all["luci-app-tachyon"];
    let perms = (acl[ARGV[1]] || {})["file"] || {};
    let list = perms[ARGV[2]] || [];
    printf("%s\n", type(list) == "array" && length(list) > 0 ? "yes" : "no");
  ' "$ACL_JSON" "$1" "$2"
}

[ "$(acl_exec read /usr/bin/tachyon)" = "no" ] ||
  fail "read role still has exec on /usr/bin/tachyon, which reaches every subcommand"

[ "$(acl_exec read /usr/bin/tachyon-read)" = "yes" ] ||
  fail "read role needs exec on /usr/bin/tachyon-read or the UI loses all status"

[ "$(acl_exec write /usr/bin/tachyon)" = "yes" ] ||
  fail "write role must keep exec on /usr/bin/tachyon"

# rpcd caches ACLs; without the reload the stricter policy is inert until rpcd
# restarts, and if it is applied late the UI is broken in between.
grep -q "init.d/rpcd reload" "$ROOT/Makefile" ||
  fail "tachyon postinst must reload rpcd, or the new ACL never takes effect"

# tachyon-read must stay a ucode script. tests/shell_inventory.sh forbids turning
# the main binary into a shell loader; the read entry point has the same reason
# to be ucode, since -L in a shebang is not delivered.
head -1 "$READ_BIN" | grep -q '^#!/usr/bin/ucode' ||
  fail "tachyon-read must be a ucode script, not a shell wrapper"
grep -qE '#!/bin/(ba)?sh|exec[[:space:]]+ucode' "$READ_BIN" &&
  fail "tachyon-read must not become a shell loader"

# Drift: every command in the read entry point must exist in the dispatcher, and
# nothing destructive may have crept in. The leading whitespace differs between
# the two files (4 vs 8 spaces) and only some keys are quoted, so the cleanup
# has to strip both.
sed -n '/^let commands = {/,/^};/p' "$READ_BIN" |
  grep -oE '^    "?[a-z0-9_-]+"?: \[' |
  sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*:[[:space:]]*\[//' | sort -u > /tmp/acl_read.txt

sed -n '/^function command_spec/,/^    };/p' "$DISPATCHER" |
  grep -oE '^        "?[a-z0-9_-]+"?: \[' |
  sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*:[[:space:]]*\[//' | sort -u > /tmp/acl_dispatch.txt

read_count=$(wc -l < /tmp/acl_read.txt)
dispatch_count=$(wc -l < /tmp/acl_dispatch.txt)

[ "$read_count" -gt 0 ] || fail "read table parsed empty, the drift check would pass vacuously"
[ "$dispatch_count" -gt 0 ] || fail "dispatcher table parsed empty, the drift check would pass vacuously"

unknown=$(comm -23 /tmp/acl_read.txt /tmp/acl_dispatch.txt)
if [ -n "$unknown" ]; then
  fail "tachyon-read offers commands the dispatcher does not have: $(echo "$unknown" | tr '\n' ' ')"
fi

# A read entry point that can rewrite the router is worse than no split at all.
# Checked against the cleaned name list, which is why this is -x and not -E.
for dangerous in emergency_reset apply_quick_fix disable enable uninstall reset_settings \
                  component_install_version component_auto_update_apply snapshot_restore \
                  known_good_restore known-good-restore fuzzer_apply fuzzer_auto_apply \
                  reconcile job_cancel job-cancel job_request_cancel import_settings \
                  dns_benchmark_apply dns_autotune generate_warp package_prerm \
                  engine_switch engine_start engine_stop restart start stop reload; do
  if grep -qxF "$dangerous" /tmp/acl_read.txt; then
    fail "tachyon-read must not offer a write command: $dangerous"
  fi
done
rm -f /tmp/acl_read.txt /tmp/acl_dispatch.txt

printf 'PASS: read role reaches only the read entry point (%s of %s commands, ACL owned by tachyon)\n' \
  "$read_count" "$dispatch_count"
