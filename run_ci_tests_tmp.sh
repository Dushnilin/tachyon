#!/usr/bin/env bash
set -uo pipefail
cd /work
echo "=== ucode syntax lint (all) ==="
find tachyon/files/usr/lib -name '*.uc' -print0 | xargs -0 -n1 ucode -c -o /dev/null 2>&1 | head -5
find tachyon/files/usr/lib -name '*.uc' -print0 | xargs -0 -n1 ucode -S -c -o /dev/null 2>&1 | head -5
echo "syntax lint done"
mkdir -p /tmp/per-test
: > /tmp/exitcodes.txt
run_one() {
  f="$1"
  base="$(basename "$f" .sh)"
  bash "$f" >/tmp/per-test/"$base".out 2>/tmp/per-test/"$base".err
  code=$?
  echo "$code $base" >>/tmp/exitcodes.txt
  if [ "$code" -ne 0 ]; then
    echo "=== FAILED: $base (exit $code) ===" >&2
    tail -6 /tmp/per-test/"$base".out >&2
    echo "--- stderr ---" >&2
    tail -6 /tmp/per-test/"$base".err >&2
  fi
}
export -f run_one
find tests -maxdepth 1 -name '*.sh' \
  ! -name 'docker_e2e_test.sh' \
  ! -name 'container_entrypoint.sh' \
  ! -name 'run_all.sh' \
  ! -name 'ucode_syntax_lint.sh' \
  ! -name 'inside_docker.sh' \
  -print0 | xargs -0 -n1 -P4 bash -c 'run_one "$@"' _
echo "=== NONZERO ==="
sort -n /tmp/exitcodes.txt | grep -v '^0 ' || echo "NONE - ALL PASSED"
echo "=== TOTAL: $(wc -l < /tmp/exitcodes.txt) tests ==="
