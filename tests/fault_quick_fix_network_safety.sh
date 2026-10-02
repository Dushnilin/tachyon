#!/usr/bin/env bash
# Two quick fixes could take the router's networking down instead of repairing it.
#
# 1. flush_conntrack chained `sysctl -w ...=65536; echo 1 > .../nf_conntrack_max`.
#    The `;` runs the write unconditionally, so the fallback always won and capped
#    the NAT table at one connection - the router lost all outbound traffic.
#
# 2. fix_resolv_symlink ran `ln -sf /tmp/resolv.conf.auto ... || ln -sf
#    /tmp/resolv.conf.d/resolv.conf.auto ...`. `ln -sf` succeeds even when the
#    target does not exist, so the fallback never fired and /etc/resolv.conf was
#    left pointing at the pre-22.03 path no OpenWrt writes any more.
#
# `ln` is stubbed on PATH so the test reads the argv the fix really runs instead
# of the source text - /etc/resolv.conf is a bind mount in the container and
# cannot be replaced. conntrack is asserted on the value literal for the same
# reason: /proc/sys is read-only here, so that write cannot be observed.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RUNTIME="$TACHYON_LIB/diagnostics/runtime.uc"
REPAIRS="$TACHYON_LIB/diagnostics/repairs.uc"
LN_LOG="$WORK_DIR/ln.log"

cleanup() {
    rm -f /tmp/resolv.conf.auto /tmp/resolv.conf.d/resolv.conf.auto
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/ln" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LN_LOG"
exit 0
EOF
chmod +x "$WORK_DIR/bin/ln"
export PATH="$WORK_DIR/bin:$PATH"

run_fix() {
    : >"$LN_LOG"
    ucode -L "$TACHYON_LIB" "$RUNTIME" apply-quick-fix fix_resolv_symlink >/dev/null 2>&1 || true
}

# --- 1. the conntrack fallback must never write a limit below the sysctl target ---
ct_line="$(grep 'nf_conntrack_max' "$REPAIRS" | grep 'echo' || true)"
[ -n "$ct_line" ] || fail "flush_conntrack no longer writes nf_conntrack_max; expected a procfs fallback"

bad="$(printf '%s\n' "$ct_line" | grep -oE 'echo [0-9]+ >' | grep -v 'echo 65536 >' || true)"
[ -z "$bad" ] || fail "flush_conntrack writes a NAT limit other than 65536: $bad"
printf 'conntrack fallback writes 65536\n' >&2

# --- 2a. link the target that actually exists ---
mkdir -p /tmp/resolv.conf.d
printf 'nameserver 192.168.1.1\n' >/tmp/resolv.conf.d/resolv.conf.auto
rm -f /tmp/resolv.conf.auto

run_fix

[ -s "$LN_LOG" ] || fail "fix_resolv_symlink ran no ln at all with a live resolv.conf.auto"
printf 'ln argv: %s\n' "$(cat "$LN_LOG")" >&2
linked="$(awk '{print $2}' "$LN_LOG" | head -n1)"
printf 'linked -> %s\n' "$linked" >&2
[ "$linked" = "/tmp/resolv.conf.d/resolv.conf.auto" ] ||
    fail "linked to '$linked' instead of the existing resolv.conf.auto"

# --- 2b. with no target present it must not create a dangling link ---
rm -f /tmp/resolv.conf.auto /tmp/resolv.conf.d/resolv.conf.auto

run_fix

[ -s "$LN_LOG" ] && fail "linked $(cat "$LN_LOG") although no resolv.conf.auto exists"
printf 'no link attempted when no target exists\n' >&2

printf 'quick fix network safety checks passed\n'