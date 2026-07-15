#!/usr/bin/env bash
set -eo pipefail

echo "=== Syntax Checking ==="
find tachyon/files/usr/lib -name "*.uc" -print0 | xargs -0 -n1 ucode -c -o /dev/null
find tachyon/files/usr/lib -name "*.uc" -print0 | xargs -0 -n1 ucode -S -c -o /dev/null

echo "=== Running Tests ==="
for f in tests/*.sh; do
  if [ "$f" != "tests/run_all.sh" ] && [ "$f" != "tests/docker_e2e_test.sh" ] && [ "$f" != "tests/container_entrypoint.sh" ]; then
    echo "Running: $f"
    bash "$f"
  fi
done
