#!/usr/bin/env bash
# steer 2.0.0 ships the core as a package called "steer-core".
#
# The resolver used to match the prefix "steer-", which on 2.0.0 is ambiguous: the
# same release also publishes "steer-hysteria2-<version>-1_<arch>.<ext>" and
# "steer-hub-<arch>.tar.gz", and the hysteria2 packages end with exactly the suffix
# the resolver required. So the first asset that matched was whichever of those came
# first in the release, and Tachyon would have installed the wrong package and called
# it the engine. There is no plain "steer-<version>-1_<arch>" asset at all any more,
# so the old prefix matched nothing on a stock 2.0.0 release.
#
# The asset list below is the real one from v2.0.0, trimmed to the steer entries.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/components" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

CATALOG="$TACHYON_LIB/components/catalog.uc"
ACTION="$TACHYON_LIB/components/action.uc"
for f in "$CATALOG" "$ACTION"; do
  [ -f "$f" ] || fail "missing $f"
done

# The v2.0.0 asset names, verbatim.
names=(
  "steer-core-2.0.0-1_aarch64_cortex-a53.apk"
  "steer-core-2.0.0-1_aarch64_cortex-a53.ipk"
  "steer-core-2.0.0-1_x86_64.ipk"
  "steer-core-2.0.0-1_mipsel_24kc.ipk"
  "steer-extended-2.0.0-1_aarch64_cortex-a53.ipk"
  "steer-extended-2.0.0-1_x86_64.ipk"
  "steer-hysteria2-2.0.0-1_aarch64_cortex-a53.ipk"
  "steer-hysteria2-2.0.0-1_x86_64.ipk"
  "steer-hub-aarch64.tar.gz"
  "steer-hub-x86_64.tar.gz"
)

{
  printf 'let assets = [\n'
  for n in "${names[@]}"; do
    printf '  { name: "%s", browser_download_url: "https://example.invalid/%s" },\n' "$n" "$n"
  done
  printf '];\n'
  printf 'print(""); // not a module\n'
} >"$WORK_DIR/assets.uc"

cat >"$WORK_DIR/pick.uc" <<'UCODE'
let catalog = require("components.catalog");

// Reproduces the resolver's asset walk against the real v2.0.0 names. Kept beside
// the source rather than in place of it: the point is that whatever prefix the
// resolver uses, it must land on steer-core and never on the sibling packages.
let prefix = ARGV[0];
let suffix = "-1_aarch64_cortex-a53.ipk";
let names = [
    "steer-core-2.0.0-1_aarch64_cortex-a53.apk",
    "steer-core-2.0.0-1_aarch64_cortex-a53.ipk",
    "steer-extended-2.0.0-1_aarch64_cortex-a53.ipk",
    "steer-hysteria2-2.0.0-1_aarch64_cortex-a53.ipk",
    "steer-hub-aarch64.tar.gz"
];

let picked = "";
for (let name in names) {
    if (substr(name, 0, length(prefix)) != prefix) continue;
    if (substr(name, length(name) - length(suffix)) != suffix) continue;
    picked = name;
    break;
}
printf("%s\n", picked);
UCODE

# The prefix the resolver actually uses, read from the source so the test cannot
# drift away from the implementation.
prefix="$(sed -n '/^function resolve_steer_release/,/let distrib_arch/p' "$CATALOG" |
  grep -oE 'let prefix = extended \? "[a-z-]+" : "[a-z-]+"' |
  grep -oE '"[a-z-]+"' | tail -1 | tr -d '"')"

[ -n "$prefix" ] || fail "could not read the standard prefix out of resolve_steer_release"
[ "$prefix" = "steer-core-" ] ||
  fail "the standard steer package is steer-core since 2.0.0, but the resolver looks for '$prefix'"
ok

picked="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/pick.uc" "$prefix" 2>/dev/null)"
[ "$picked" = "steer-core-2.0.0-1_aarch64_cortex-a53.ipk" ] ||
  fail "the standard install would fetch '$picked' instead of the steer core package"
ok

# The prefix alone is not enough: the sibling packages share the suffix, so the walk
# must also refuse anything that is not one of the two steer packages.
if grep -q 'str_startswith(name, "steer-hysteria2' "$CATALOG"; then
  fail "the resolver filters sibling packages by name, which will not survive the next one"
fi
ok

body="$(sed -n '/^function resolve_steer_release/,/^}/p' "$CATALOG")"
if ! grep -q 'steer-core-' <<<"$body"; then
  fail "resolve_steer_release must guard the prefix again inside the asset walk"
fi
ok

# Installing must know the new package name, and the version check must still see a
# router that only has the old one.
grep -q 'STEER_CORE_PACKAGE = "steer-core"' "$ACTION" ||
  fail "action.uc must name the steer core package"
ok

grep -q 'function installed_steer_version' "$ACTION" ||
  fail "action.uc must resolve the installed steer version across both package names"
ok

install_body="$(sed -n '/^function install_steer/,/^}/p' "$ACTION")"
[ -n "$install_body" ] || fail "install_steer not found"

grep -q 'installed_steer_version()' <<<"$install_body" ||
  fail "the check_update path still asks only about the old package name"
ok

# Every conflicting name has to be considered. steer-core is named through the
# constant, so it is resolved rather than grepped as a literal.
grep -q 'STEER_CORE_PACKAGE' <<<"$install_body" ||
  fail "install_steer does not consider the steer-core package when resolving conflicts"
ok

for other in '"steer"' '"steer-extended"'; do
  if ! grep -q -- "$other" <<<"$install_body"; then
    fail "install_steer does not consider the $other package when resolving conflicts"
  fi
  ok
done

printf 'steer package naming: %d checks passed\n' "$pass_count"
printf 'PASS: steer_package_naming\n'