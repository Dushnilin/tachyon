#!/usr/bin/env bash
# Four bugs from the 1.4.8 ticket batch, each asserted against the source that
# produces the behaviour. They are grouped in one file because all four are the
# same shape of mistake: a helper existed and was not used, or a function did the
# opposite of what its name said.
#
#  #94  tailscaled was spawned with a hand-rolled '& echo $!', inheriting procd's
#       lock descriptor fd 1000. The flock belongs to the open file, not the
#       process, so every later /etc/init.d/tachyon reload blocked forever.
#  #97  DNS rules for fakeip domains carried no query_type, and the fakeip server
#       only answers A and AAAA, so MX/SRV/TXT waited out the client timeout.
#  #98  hup_sing_box_runtime() was named for SIGHUP and did a full restart.
#  #95  the "additional marking rules" check counted Tachyon's own fw4 rules,
#       and --netfilter-mode was probed on tailscaled while it is a client flag.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TAILSCALE_RT="$TACHYON_LIB/providers/tailscale/runtime.uc"
FPTN_RT="$TACHYON_LIB/providers/fptn/runtime.uc"
ROUTES="$TACHYON_LIB/singbox/generator_routes.uc"
GEN="$TACHYON_LIB/singbox/generator.uc"
STATE="$TACHYON_LIB/service/state.uc"
ROUTING_DIAG="$TACHYON_LIB/diagnostics/routing.uc"
STATUS_DIAG="$TACHYON_LIB/diagnostics/status.uc"
for f in "$TAILSCALE_RT" "$FPTN_RT" "$ROUTES" "$GEN" "$STATE" "$ROUTING_DIAG" "$STATUS_DIAG"; do
  [ -f "$f" ] || fail "missing $f"
done

# --- #94: no hand-rolled background spawn in the two runtimes -------------
grep -q 'background_command_with_pid' "$TAILSCALE_RT" ||
  fail "tailscaled must be spawned through background_command_with_pid, or it inherits procd's fd 1000 and every later reload deadlocks on flock 1000"
ok

# The fix's own comment names the construct it removed, so only executable lines count here.
grep 'echo \$!' "$TAILSCALE_RT" | grep -qv '^[[:space:]]*//' &&
  fail "tailscale/runtime.uc still spawns with a raw '& echo \$!', which redirects only 0/1/2 and leaks the lock descriptor into tailscaled"
ok

grep -q 'background_command_with_pid' "$FPTN_RT" ||
  fail "fptn/runtime.uc must spawn through background_command_with_pid for the same fd-1000 reason"
ok

grep 'echo \$! > ' "$FPTN_RT" | grep -qv '^[[:space:]]*//' &&
  fail "fptn/runtime.uc still spawns with a raw '& echo \$! > pid', same descriptor leak"
ok

# --- #97: fakeip-routed DNS rules must declare the types fakeip can answer --
grep -q 'function add_fakeip_query_type' "$ROUTES" ||
  fail "generator_routes.uc must keep add_fakeip_query_type(): without query_type every non-A/AAAA query for a fakeip domain is sent to a server that cannot answer it"
ok

fakeip_sites="$(grep -c 'add_fakeip_query_type(dns_rule, section_dns_server(section))' "$ROUTES")"
[ "$fakeip_sites" -ge 3 ] ||
  fail "all three section DNS rule sites must call add_fakeip_query_type, found $fakeip_sites"
ok

grep -q 'query_type: \[ "A", "AAAA" \]' "$GEN" ||
  fail "the fakeip rule for the diagnostic domains must also restrict query_type to A and AAAA"
ok

# --- #98: the function named for SIGHUP has to send SIGHUP -----------------
grep -q 'Applying DNS failover with sing-box service restart' "$STATE" &&
  fail "hup_sing_box_runtime() is announcing a full restart again"
ok

hup_line="$(grep -n '^function hup_sing_box_runtime' "$STATE" | cut -d: -f1)"
sighup_line="$(grep -n '^function try_sighup_reload' "$STATE" | cut -d: -f1)"
[ -n "$hup_line" ] && [ -n "$sighup_line" ] || fail "cannot locate the SIGHUP functions in state.uc"
[ "$sighup_line" -lt "$hup_line" ] ||
  fail "hup_sing_box_runtime() calls try_sighup_reload(), so it must be declared after it: ucode resolves a module-level function where the caller is defined, and a forward reference becomes 'left-hand side is not a function' at runtime"
ok

grep -q 'Applying DNS failover via sing-box SIGHUP' "$STATE" ||
  fail "hup_sing_box_runtime() must log the graceful SIGHUP path it now takes"
ok

# --- #95: Tachyon's own marks are not "another package's" marks ------------
grep -q 'TACHYON_OWN_MARKS' "$ROUTING_DIAG" ||
  fail "diagnostics/routing.uc must know which marks belong to Tachyon, or its own fw4 rules are reported as a foreign marking rule"
ok

grep -q 'TACHYON_OWN_MARKS' "$STATUS_DIAG" ||
  fail "diagnostics/status.uc must filter Tachyon's own marks out of the printed list"
ok

grep -q 'netfilter_mode_supported_by_client' "$TAILSCALE_RT" ||
  fail "tailscale/runtime.uc must probe the client for --netfilter-mode; asking tailscaled made 'tailscale up' never receive the flag on current versions"
ok

grep -q 'netfilter_mode_supported_by_daemon' "$TAILSCALE_RT" ||
  fail "the daemon spawn path must keep its own --netfilter-mode probe"
ok

# --- #95: and it has to behave, not merely exist ---------------------------
# A symbol check is not enough here: the first version of this filter compared
# token[1], which a capture-less /g match never sets, so every line looked foreign
# and the false positive survived a green test. Drive the real entry point.
printf 'table inet fw4\n\tmeta mark 0x04000000 return\n\tmeta mark & 0x04000000 == 0x04000000 accept comment "Allow Tachyon TPROXY marked traffic"\n' >"$WORK_DIR/ours.txt"
printf 'table inet TachyonTable\n\tmeta mark set meta mark | 0x08000000\ntable inet fw4\n\tmeta mark 0x04000000 return\ntable ip filter\n\tiifname "tailscale0*" counter meta mark set meta mark & 0xffff04ff | 0x00000400\n' >"$WORK_DIR/mixed.txt"

printed="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$STATUS_DIAG" nft-ruleset-other-mark-lines TachyonTable <"$WORK_DIR/ours.txt" 2>/dev/null || true)"
[ -z "$printed" ] ||
  fail "Tachyon's own fw4 rules must not be reported as another package's marking rules, got: $printed"
ok

mixed="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$STATUS_DIAG" nft-ruleset-other-mark-lines TachyonTable <"$WORK_DIR/mixed.txt" 2>/dev/null || true)"
printf '%s' "$mixed" | grep -q '0xffff04ff' ||
  fail "a genuinely foreign mark rule (tailscale) must still be reported, got: $mixed"
ok

printf '%s' "$mixed" | grep -q '0x04000000' &&
  fail "the Tachyon mark must not survive into the printed list, got: $mixed"
ok

printf 'ticket batch 94/95/97/98: %d checks passed\n' "$pass_count"
printf 'PASS: ticket_batch_providers_and_dns\n'