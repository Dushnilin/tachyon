#!/usr/bin/env bash
# The fuzzer queue rule has to be valid nft syntax.
#
# This is the check whose absence shipped a broken fuzzer to every user on 1.4.9.
# The per-protocol counters were added with the comment placed before the verdict:
#
#   ... counter comment "tcp-proto" queue num 200
#
# nft parses counter, comment and queue as rule statements and rejects that order
# with "syntax error, unexpected queue". The fuzzer builds its table with stderr
# discarded, so the only symptom was "nftables setup failed: fuzzer queue rule could
# not be installed" on every strategy - the tool entirely dead, with no reason given.
#
# The earlier test asserted that the string comment "tcp-proto" existed in the
# source and that parse_proto_counters() understood real nft output. Both passed
# while the generated rule was invalid: nothing ever handed a rule to nft. This one
# does, through nft --check, and it also proves the check has teeth by feeding it the
# ordering that broke.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/diagnostics" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

if ! command -v nft >/dev/null 2>&1; then
  fail "nft is not installed; this test exists because nothing else parsed the generated rule (add nftables to tests/Dockerfile.test and backend-ci.yml)"
fi

# nft --check reports a parse failure as "syntax error" on stderr. Applying a rule
# needs privileges we do not have and the queue verdict may still be rejected by the
# kernel, so the exit code alone is not the signal - the message is.
syntax_error() { # <file>
  nft --check -f "$1" 2>&1 | grep -c 'syntax error' || true
}

cat >"$WORK_DIR/spec.uc" <<'UCODE'
let b = require("diagnostics.fuzzer.binaries");
let protocol = ARGV[0];
let ports = protocol == "udp" ? b.FUZZER_QUEUE_PORTS_UDP : b.FUZZER_QUEUE_PORTS_TCP;
print(b.fuzzer_queue_rule_spec("ip daddr { 203.0.113.7 } ", protocol, 200, ports));
UCODE

for protocol in tcp udp; do
  rule="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/spec.uc" "$protocol")"

  {
    printf 'add table inet fz_syntax\n'
    printf 'add chain inet fz_syntax postnat { type filter hook postrouting priority 101 ; policy accept; }\n'
    printf '%s\n' "$rule"
  } >"$WORK_DIR/good-$protocol.nft"

  if [ "$(syntax_error "$WORK_DIR/good-$protocol.nft")" != "0" ]; then
    nft --check -f "$WORK_DIR/good-$protocol.nft" 2>&1 | sed 's/^/  /' >&2
    fail "the $protocol queue rule is not valid nft syntax:
$rule"
  fi
  ok

  # Teeth: the ordering that shipped must be rejected by the same check.
  broken="$(sed 's/counter queue num \([0-9]*\) comment \("[a-z]*-proto"\)/counter comment \2 queue num \1/' <<<"$rule")"
  if [ "$broken" = "$rule" ]; then
    fail "could not build the broken variant of the $protocol rule for the negative check:
$rule"
  fi
  {
    printf 'add table inet fz_syntax\n'
    printf 'add chain inet fz_syntax postnat { type filter hook postrouting priority 101 ; policy accept; }\n'
    printf '%s\n' "$broken"
  } >"$WORK_DIR/bad-$protocol.nft"

  if [ "$(syntax_error "$WORK_DIR/bad-$protocol.nft")" = "0" ]; then
    fail "nft --check accepted a comment before the verdict, so this test cannot detect that mistake:
$broken"
  fi
  ok
done

# The verdict has to come before the comment in the generated text as well, so the
# property does not depend on nft's leniency.
for protocol in tcp udp; do
  rule="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/spec.uc" "$protocol")"
  queue_at="${rule%%queue num*}"
  case "$queue_at" in
    *comment*) fail "the $protocol rule puts the comment before the verdict: $rule" ;;
  esac
  ok
done

printf 'fuzzer nft rule syntax: %d checks passed\n' "$pass_count"
printf 'PASS: fuzzer_nft_rule_syntax\n'