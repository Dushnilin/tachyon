#!/usr/bin/env bash
set -euo pipefail

# Node is already required by the frontend build (tsup/vitest) and by
# rag_build_index.js, so the tree keeps a single indexer implementation. This
# script used to carry a second, ~120 line python3 copy of the same chunking
# logic; the two had already drifted (CHUNK_SIZE/CHUNK_OVERLAP were honoured
# only by the python branch).

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DOCS_DIR="${1:-$ROOT_DIR/docs/knowledge-base}"
OUTPUT_DIR="${2:-$ROOT_DIR/tachyon/files/usr/lib}"

command -v node >/dev/null 2>&1 || {
    echo "rag_build_index: node is required" >&2
    exit 1
}

exec node "$SCRIPT_DIR/rag_build_index.js" "$DOCS_DIR" "$OUTPUT_DIR/rag_index.json"
