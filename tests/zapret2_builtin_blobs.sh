#!/usr/bin/env bash
# zapret2 1.0.5+ compiles fake_default_http/tls/quic into nfqws2. Passing
# --blob= for a name the binary already has is a fatal "duplicate blob name" and
# the daemon never starts, which is what a clean install hit: its default
# strategy carries no --lua-init, so blob resolution runs and collides.
#
# The stub nfqws2 below reports exactly the two names a stock 1.0.5.x build has
# compiled in, so the test asserts both halves: built-ins are left alone, and
# everything else still gets its --blob= flag.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi

mkdir -p "$WORK_DIR/files/fake"
printf 'blob' > "$WORK_DIR/files/fake/quic_initial_www_google_com.bin"
printf 'blob' > "$WORK_DIR/files/fake/discord-ip-discovery-with-port.bin"

cat > "$WORK_DIR/nfqws2" <<'STUB'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    --blob=fake_default_quic:*|--blob=fake_default_http:*|--blob=fake_default_tls:*)
      name="${arg#--blob=}"
      echo "duplicate blob name '${name%%:*}'" >&2
      exit 0
      ;;
  esac
done
echo "command line parameters verified"
STUB
chmod +x "$WORK_DIR/nfqws2"

export ZAPRET2_PROVIDER_FILES_DIR="$WORK_DIR/files"
export ZAPRET2_NFQWS2_BIN="$WORK_DIR/nfqws2"

ucode -L "$TACHYON_LIB" -e '
let zapret2 = require("providers.zapret2.common");
let cfg = zapret2.config();

function flags(list) {
    let out = [];
    for (let a in list) push(out, a);
    return join(" ", out);
}

// The shipped default strategy references fake_default_quic and nothing else.
// Leaving its --blob= off is the whole fix.
if (index(cfg.default_strategy, "blob=fake_default_quic") < 0)
    die("default strategy no longer references fake_default_quic\n");

let def = flags(cfg.prepare_strategy_args(cfg.default_strategy));
if (index(def, "--blob=") >= 0)
    die("default strategy still gets a --blob= flag, nfqws2 will die: " + def + "\n");

// A blob the binary does not know must still be resolved from the files dir.
let discord = flags(cfg.prepare_strategy_args("--lua-desync=fake:blob=fake_discord:repeats=2"));
if (index(discord, "--blob=fake_discord:@") < 0)
    die("fake_discord must keep its --blob= flag: " + discord + "\n");

if (index(discord, "quic_initial_www_google_com.bin") >= 0)
    die("fake_discord resolved to the wrong file: " + discord + "\n");

// --lua-init strategies were already skipped, and stay skipped.
let lua = flags(cfg.prepare_strategy_args("--lua-init=@/x --lua-desync=fake:blob=fake_discord"));
if (index(lua, "--blob=") >= 0)
    die("--lua-init strategy must not resolve blobs: " + lua + "\n");
' || fail "zapret2 builtin blob guard verification failed"

printf 'PASS: zapret2_builtin_blobs\n'
