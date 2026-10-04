#!/usr/bin/env bash
# Asking whether a flag exists must not be the thing that runs the command.
#
# netfilter_help_has_flag() probed with `tailscale up` - no arguments. That is not a
# help query, it is the command that connects or changes preferences, so a read-only
# capability check could bring the client up or rewrite its settings. It also read
# the wrong text: on 1.98.3 the flag is declared by `tailscale up --help` and not by
# the general `tailscale --help`, so the client never received --netfilter-mode,
# tailscaled installed its own netfilter rules, and the router ended up with ip
# filter / ip6 filter / nat / mangle tables that the diagnostics then reported as
# foreign marking rules.
#
# On OpenWrt 1.98.3-1 both binaries print that help on stderr (Go flag package), and
# the generic command_output_from_args() redirects stderr to /dev/null - so a probe
# reading only stdout saw an empty help text and answered no (#110). The stubs can
# print the flag on stderr to keep that regression visible.
#
# The binaries are stubbed here, so the test can prove which argv each one is asked
# with rather than only inspecting the source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/providers" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

RUNTIME_UC="$TACHYON_LIB/providers/tailscale/runtime.uc"
[ -f "$RUNTIME_UC" ] || fail "missing $RUNTIME_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# A client that records how it was invoked and only mentions the flag in "up --help".
# TAILSCALE_SUPPORT_CLIENT / _DAEMON let a case pretend the flag does not exist,
# TAILSCALE_*_STDERR moves the help text to stderr the way OpenWrt 1.98.3 prints it.
cat >"$WORK_DIR/tailscale" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PROBE_LOG"
case "$*" in
  "up --help")
    if [ "$TAILSCALE_SUPPORT_CLIENT" = "yes" ]; then
      if [ "$TAILSCALE_CLIENT_STDERR" = "yes" ]; then
        printf '  --netfilter-mode=<mode>  netfilter mode (off|on)\n' >&2
      else
        printf '  --netfilter-mode=<mode>  netfilter mode (off|on)\n'
      fi
    else
      printf '  --accept-dns=<bool>  accept DNS\n'
    fi ;;
  *) printf '  Usage: tailscale [command]\n' ;;
esac
exit 0
SH

cat >"$WORK_DIR/tailscaled" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PROBE_LOG"
case "$*" in
  "--help")
    if [ "$TAILSCALE_SUPPORT_DAEMON" = "yes" ]; then
      if [ "$TAILSCALED_STDERR" = "yes" ]; then
        printf '  --netfilter-mode=<mode>  netfilter mode\n' >&2
      else
        printf '  --netfilter-mode=<mode>  netfilter mode\n'
      fi
    else
      printf '  --tun=<bool>  tun\n'
    fi ;;
  *) printf 'Usage: tailscaled [command]\n' ;;
esac
exit 0
SH
chmod 0755 "$WORK_DIR/tailscale" "$WORK_DIR/tailscaled"

probe() { # <client-supports> <daemon-supports> [client-stderr] [daemon-stderr]
  rm -f "$WORK_DIR/probe.log"
  PROBE_LOG="$WORK_DIR/probe.log" \
  TAILSCALE_BIN="$WORK_DIR/tailscale" \
  TAILSCALED_BIN="$WORK_DIR/tailscaled" \
  TAILSCALE_SUPPORT_CLIENT="$1" \
  TAILSCALE_SUPPORT_DAEMON="$2" \
  TAILSCALE_CLIENT_STDERR="${3:-no}" \
  TAILSCALED_STDERR="${4:-no}" \
    ucode -e '
      let r = require("providers.tailscale.netfilter_probe");
      // print does not append a newline in ucode.
      printf("client=%s\n", r.netfilter_mode_supported_by_client() ? "yes" : "no");
      printf("daemon=%s\n", r.netfilter_mode_supported_by_daemon() ? "yes" : "no");
    ' 2>/dev/null
}

out="$(probe yes yes)"
client="$(sed -n 's/^client=//p' <<<"$out")"
daemon="$(sed -n 's/^daemon=//p' <<<"$out")"

[ "$client" = "yes" ] ||
  fail "the client must be detected as supporting --netfilter-mode, got '$client'"
ok

[ "$daemon" = "yes" ] ||
  fail "tailscaled must be detected as supporting --netfilter-mode, got '$daemon'"
ok

# The client must be asked with "up --help": that is where the flag is documented,
# and "up" alone is a state-changing command.
grep -q '^up --help$' "$WORK_DIR/probe.log" ||
  fail "the client must be probed with 'up --help', probe log was:
$(cat "$WORK_DIR/probe.log")"
ok

if grep -qx 'up' "$WORK_DIR/probe.log"; then
  fail "the probe ran bare 'tailscale up', which connects or changes preferences instead of printing help:
$(cat "$WORK_DIR/probe.log")"
fi
ok

# tailscaled is a daemon: "--help" is the help query there, and no probe may run a
# bare "up" - that is the connect command.
if grep -qx 'up' "$WORK_DIR/probe.log"; then
  fail "a probe ran bare 'up', which connects or changes preferences instead of printing help:
$(cat "$WORK_DIR/probe.log")"
fi
ok

if grep -q '^up' "$WORK_DIR/probe.log" && ! grep -qx 'up --help' "$WORK_DIR/probe.log"; then
  fail "the daemon must not be probed with an 'up' subcommand:
$(cat "$WORK_DIR/probe.log")"
fi
ok

# A client that does not know the flag must not be reported as supporting it, and
# the daemon must be judged on its own help rather than on the client's.
out="$(probe no yes)"
client="$(sed -n 's/^client=//p' <<<"$out")"
daemon="$(sed -n 's/^daemon=//p' <<<"$out")"
[ "$client" = "no" ] ||
  fail "a client without the flag in its help must report no, got '$client'"
ok

[ "$daemon" = "yes" ] ||
  fail "the daemon answer must not depend on the client's help, got '$daemon'"
ok

out="$(probe no no)"
client="$(sed -n 's/^client=//p' <<<"$out")"
daemon="$(sed -n 's/^daemon=//p' <<<"$out")"
[ "$client" = "no" ] || fail "client should be no, got '$client'"
ok
[ "$daemon" = "no" ] || fail "daemon should be no, got '$daemon'"
ok

# OpenWrt 1.98.3 prints that help on stderr (#110): command_output_from_args() sends
# stderr to /dev/null, so a stdout-only capture reads an empty help and answers no.
# Both binaries must still be detected when the only copy of the flag lives on stderr.
out="$(probe yes yes yes yes)"
client="$(sed -n 's/^client=//p' <<<"$out")"
daemon="$(sed -n 's/^daemon=//p' <<<"$out")"
[ "$client" = "yes" ] ||
  fail "help printed on stderr must still be read by the probe, got '$client'"
ok
[ "$daemon" = "yes" ] ||
  fail "the daemon help printed on stderr must still be read by the probe, got '$daemon'"
ok

# Content, not the stream: a binary that says nothing about the flag must answer no
# even when its help text goes to stderr - otherwise "2>&1" would pass vacuously.
out="$(probe no no yes yes)"
client="$(sed -n 's/^client=//p' <<<"$out")"
daemon="$(sed -n 's/^daemon=//p' <<<"$out")"
[ "$client" = "no" ] ||
  fail "stderr help without the flag must not be reported as support, got '$client'"
ok
[ "$daemon" = "no" ] ||
  fail "stderr daemon help without the flag must not be reported as support, got '$daemon'"
ok

printf 'tailscale netfilter probe: %d checks passed\n' "$pass_count"
printf 'PASS: tailscale_netfilter_probe\n'