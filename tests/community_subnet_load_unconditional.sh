#!/usr/bin/env bash
# Community subnets must be loaded for EVERY section, not only for sections that
# happen to have priority matchers.
#
# The failure this pins (TCH-1041): the load sat inside the
# section_needs_priority_sets() branch in nft/apply.uc, which requires an
# ip/port/dscp/source matcher plus a priority action. A section carrying
# community_lists but none of those got no community subnets at all — the rules
# still referenced the set, the set stayed empty, and nothing was logged. It
# surfaced on a user router as "empty nftables subnets sets (community) — data
# was not loaded on reload", auto-remediated by the Reconciler from the
# persistent cache, which hides rather than fixes it.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY_UC="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$APPLY_UC" ] || fail "nft/apply.uc not found"

# Line of the enclosing function that decides whether the priority branch runs.
gate_line="$(grep -n 'if (section_needs_priority_sets(section)) {' "$APPLY_UC" | tail -1 | cut -d: -f1)"
[ -n "$gate_line" ] || fail "could not locate the section_needs_priority_sets gate"

# Brace-match forward to find where that branch closes.
branch_end="$(
  awk -v start="$gate_line" '
    NR < start { next }
    {
      depth += gsub(/\{/, "{")
      depth -= gsub(/\}/, "}")
      if (NR > start && depth == 0) { print NR; exit }
    }
  ' "$APPLY_UC"
)"
[ -n "$branch_end" ] || fail "could not determine where the priority branch ends"

# The community loader must exist as its own function and be called after the
# branch closes, i.e. unconditionally.
call_line="$(grep -n '^ *nft_load_community_subnets(section, table, common_set' "$APPLY_UC" | cut -d: -f1 | head -1)"
[ -n "$call_line" ] || fail "nft_load_community_subnets() is never called"

fn_line="$(grep -n '^function nft_load_community_subnets' "$APPLY_UC" | cut -d: -f1 | head -1)"
[ -n "$fn_line" ] || fail "nft_load_community_subnets() is not defined"

if [ "$call_line" -le "$fn_line" ]; then
  fail "nft_load_community_subnets() is called before it is defined (ucode does not hoist function declarations)"
fi

if [ "$call_line" -le "$branch_end" ]; then
  fail "community subnets are still loaded inside the section_needs_priority_sets branch (ends at line $branch_end, call at $call_line)"
fi

# The old inline load, which was the one gated, must be gone.
if grep -q 'nft_add_community_subnet_file_to_family_sets(path, table, sets.subnets' "$APPLY_UC"; then
  fail "the gated inline community subnet load is still present"
fi

# Set selection must fall back to the shared sets when the section has no
# priority sets, instead of writing into per-section sets that do not exist.
grep -q 'priority ? priority.subnets : default_arg(common_set, "tachyon_subnets")' "$APPLY_UC" ||
  fail "community subnets do not fall back to the shared tachyon_subnets set"
grep -q 'priority ? priority.subnets6 : default_arg(common6_set, "tachyon_subnets6")' "$APPLY_UC" ||
  fail "community subnets do not fall back to the shared tachyon_subnets6 set"

# A missing or truncated list file must be reported. An empty set is otherwise
# indistinguishable from a section that simply matched nothing.
grep -q 'if (!loaded)' "$APPLY_UC" ||
  fail "a missing community subnet file is not reported"
grep -q 'log_warn("community subnets for "' "$APPLY_UC" ||
  fail "the missing-file diagnostic is missing"

# Both cache locations are still consulted: /tmp is tmpfs and empty after a
# reboot, so the persistent /etc copy is what makes reload work.
grep -q '/etc/tachyon/rulesets/community-subnets-' "$APPLY_UC" ||
  fail "the persistent community subnet cache is no longer read"
grep -q '/tmp/sing-box/rulesets/community-subnets-' "$APPLY_UC" ||
  fail "the tmp community subnet cache is no longer read"

printf 'community subnets load for every section: checks passed\n'
