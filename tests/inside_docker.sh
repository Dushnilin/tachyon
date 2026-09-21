#!/bin/bash
# Local helper: run the full backend test suite inside the tachyon-test Docker
# container. Usage (from the repo root, on the host):
#   docker run --rm -v '<repo>:/work' -w /work tachyon-test bash tests/inside_docker.sh
set -eo pipefail

cd /work || exit 1
UCODE_BIN="$(command -v ucode)"
export UCODE_BIN
export TACHYON_LIB=/work/tachyon/files/usr/lib

echo "=== ucode: $UCODE_BIN ==="
"$UCODE_BIN" -e 'print("ucode works")'

echo ""
echo "=== ucode syntax lint ==="
find tachyon/files/usr/lib -name '*.uc' -print0 | xargs -0 -n1 "$UCODE_BIN" -c -o /dev/null 2>&1
echo "=== pass 1 done ==="
find tachyon/files/usr/lib -name '*.uc' -print0 | xargs -0 -n1 "$UCODE_BIN" -S -c -o /dev/null 2>&1
echo "=== syntax lint PASSED ==="

echo ""
echo "=== running all backend tests ==="
find tests -maxdepth 1 -name '*.sh' \
  ! -name 'docker_e2e_test.sh' \
  ! -name 'container_entrypoint.sh' \
  ! -name 'run_all.sh' \
  ! -name 'ucode_syntax_lint.sh' \
  ! -name 'inside_docker.sh' \
  -print0 | xargs -0 -n1 -P4 bash
echo ""
echo "=== ALL TESTS PASSED ==="
