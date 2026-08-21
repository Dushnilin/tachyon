#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
export TACHYON_LIB="$TACHYON_LIB"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

RAG_UC="$TACHYON_LIB/diagnostics/rag.uc"
RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"

# 1. Regression for the inverted push(): collecting vectors from an
# OpenAI-format response must append each embedding into the result array,
# not append the (still empty) result array into each source embedding -
# which silently made RAG return "" for every primary provider.
grep -Fq 'push(embeddings, data.data[i].embedding);' "$RAG_UC" ||
  fail "rag.uc must collect embeddings into the result array"
grep -Fq 'push(data.data[i].embedding, embeddings);' "$RAG_UC" &&
  fail "rag.uc still contains the inverted push(embedding, result) call"

# 2. The cached embeddings are keyed by an index fingerprint so a rebuilt
# index cannot serve stale vectors forever.
grep -Fq 'cached.index_stamp == stamp' "$RAG_UC" ||
  fail "rag.uc cache validation must compare the index fingerprint"
grep -Fq 'function index_stamp()' "$RAG_UC" ||
  fail "rag.uc must define index_stamp()"
grep -Fq 'index_stamp: index_stamp(),' "$RAG_UC" ||
  fail "rag.uc must persist the index fingerprint alongside the cache"

# 3. A null/unset model override must be normalized before use; previously a
# use-before-declaration produced model:null payloads rejected by APIs.
grep -Fq 'model_override = trim(as_string(model_override));' "$RAG_UC" ||
  fail "rag.uc get_embedding_model must normalize a null model override"

# 4. runtime.uc must declare model_override before the RAG call consumes it.
rag_line="$(grep -n 'rag_context = rag.retrieve' "$RUNTIME_UC" | cut -d: -f1)"
decl_line="$(grep -n 'let model_override = trim(cfg.ai_doctor_model' "$RUNTIME_UC" | cut -d: -f1)"
[ -n "$rag_line" ] && [ -n "$decl_line" ] ||
  fail "runtime.uc must contain both the rag.retrieve call and its model_override declaration"
[ "$decl_line" -lt "$rag_line" ] ||
  fail "runtime.uc declares model_override AFTER rag.retrieve uses it (ucode does not hoist)"

# 5. Pin the actual push() semantics of this ucode build so the fixed code
    # above stays meaningful across toolchain updates.
push_check="$(ucode -e '
let source = [[1,2],[3,4]];
let out = [];
for (let i = 0; i < length(source); i++)
    push(out, source[i]);
print((length(out) == 2 && length(out[0]) == 2 && out[1][1] == 4) ? "OK" : "BAD");
' 2>/dev/null || echo BAD)"
[ "$push_check" = "OK" ] ||
  fail "ucode push(array, value) did not behave as expected (saw '$push_check')"

printf 'rag embeddings checks passed\n'
