#!/usr/bin/env bash
set -eo pipefail

echo "=== Syntax Checking ==="
bash tests/ucode_syntax_lint.sh

echo "=== Running Tests ==="
for f in tests/*.sh; do
  if [ "$f" != "tests/run_all.sh" ] && [ "$f" != "tests/ucode_syntax_lint.sh" ] && [ "$f" != "tests/docker_e2e_test.sh" ] && [ "$f" != "tests/container_entrypoint.sh" ]; then
    echo "Running: $f"
    bash "$f"
  fi
done
