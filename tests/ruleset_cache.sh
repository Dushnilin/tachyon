#!/usr/bin/env bash
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  echo "skip: python3 unavailable in this container"
  exit 0
fi
python3 "$(dirname "${BASH_SOURCE[0]}")/ruleset_cache_test.py"
