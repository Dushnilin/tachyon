#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Linting ucode files in $ROOT_DIR ==="

find "$ROOT_DIR/tachyon/files/usr/lib" -name "*.uc" -print0 | while IFS= read -r -d '' file; do
    echo "Checking: ${file#$ROOT_DIR/}"
    ucode -c "$file" -o /dev/null
    ucode -S -c "$file" -o /dev/null
done

echo "All ucode files compiled successfully."
