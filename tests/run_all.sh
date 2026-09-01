#!/usr/bin/env bash
# Runs the whole test suite. Mirrors CI (backend-ci.yml): syntax check first,
# then every standalone test in parallel with a pass/fail summary at the end.
#
# Usage: bash tests/run_all.sh [-P N] [test-name...]
#   -P N            run N tests in parallel (default: 4)
#   test-name...    only run tests whose file name contains these substrings
set -uo pipefail

PARALLEL=4
while getopts "P:" opt; do
  case "$opt" in
    P) PARALLEL="$OPTARG" ;;
    *) echo "Usage: bash tests/run_all.sh [-P N] [test-name...]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

echo "=== Syntax Checking ==="
if ! bash tests/ucode_syntax_lint.sh; then
  echo ""
  echo "=== Syntax check failed, aborting ==="
  exit 1
fi

test_files=()
for f in tests/*.sh; do
  case "$f" in
    tests/run_all.sh | tests/ucode_syntax_lint.sh | tests/docker_e2e_test.sh | tests/container_entrypoint.sh)
      continue
      ;;
  esac
  if [ $# -gt 0 ]; then
    name="$(basename "$f")"
    keep=0
    for pattern in "$@"; do
      case "$name" in
        *"$pattern"*) keep=1; break ;;
      esac
    done
    [ "$keep" -eq 1 ] || continue
  fi
  test_files+=("$f")
done

if [ "${#test_files[@]}" -eq 0 ]; then
  echo "No matching tests found."
  exit 1
fi

echo "=== Running ${#test_files[@]} Tests (-P $PARALLEL) ==="

results_dir="$(mktemp -d /tmp/tachyon-run-all-XXXXXX 2>/dev/null || mktemp -d)"
cleanup() { rm -rf "$results_dir"; }
trap cleanup EXIT

run_one() {
  local f="$1"
  local results_dir="$2"
  local name
  name="$(basename "$f")"
  local log="$results_dir/${name%.sh}.log"
  echo "--- START $name ---"
  if bash "$f" >"$log" 2>&1; then
    echo "--- PASS  $name ---"
  else
    echo "--- FAIL  $name ---"
  fi
}

progress_log="$results_dir/progress.log"
touch "$progress_log"

running=0
for f in "${test_files[@]}"; do
  ( run_one "$f" "$results_dir" | tee -a "$progress_log" ) &
  running=$((running + 1))
  if [ "$running" -ge "$PARALLEL" ]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done
wait

pass_count=0
fail_count=0
failed_names=()
for f in "${test_files[@]}"; do
  name="$(basename "$f")"
  log="$results_dir/${name%.sh}.log"
  # shellcheck disable=SC1091
  if grep -q -- "--- PASS  $name ---" "$results_dir/progress.log"; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    failed_names+=("$name")
  fi
done

echo ""
echo "=== Summary: $pass_count passed, $fail_count failed / total ${#test_files[@]} ==="

if [ "$fail_count" -gt 0 ]; then
  for name in "${failed_names[@]}"; do
    echo ""
    echo "--- Failure output: $name ---"
    cat "$results_dir/${name%.sh}.log"
  done
  exit 1
fi

echo "ALL PASSED"
