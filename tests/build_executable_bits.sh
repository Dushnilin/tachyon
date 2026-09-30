#!/usr/bin/env bash
# The Makefile installs executables with $(INSTALL_BIN), which implies 0755.
# build.sh has no such macro: it stages files with install -m and then calls
# normalize_package_root_modes, which sets *every* file to 0644, and restores
# the executable ones from an explicit chmod list.
#
# A file added to the staging step but forgotten in that list ships non-executable
# and fails only on the router, as "Permission denied" from a binary the ACL
# already grants exec on. That is exactly how tachyon-read shipped in 1.4.4:
# the split of the read role off the main binary, the whole point of which was a
# working read-only entry point, produced a read-only file.
#
# So every destination the Makefile installs via $(INSTALL_BIN) must be named in
# a chmod 0755 statement in build.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

MAKEFILE="$ROOT_DIR/tachyon/Makefile"
BUILD_SH="$ROOT_DIR/build.sh"

[ -f "$MAKEFILE" ] || fail "tachyon Makefile missing"
[ -f "$BUILD_SH" ] || fail "build.sh missing"

# Basenames named in any chmod 0755 statement in build.sh, following the
# backslash continuations that spread one call over several lines.
chmod_targets="$(awk '
  /chmod 0755/ { inlist = 1 }
  inlist {
    line = $0
    gsub(/"/, " ", line)
    n = split(line, parts, " ")
    for (i = 1; i <= n; i++)
      if (parts[i] ~ /\$output_root\//) {
        sub(/.*\//, "", parts[i])
        print parts[i]
      }
    if ($0 !~ /\\$/) inlist = 0
  }
' "$BUILD_SH" | LC_ALL=C sort -u)"

[ -n "$chmod_targets" ] || fail "no chmod 0755 targets parsed from build.sh, the awk checked nothing"

checked=0
missing=0
while read -r line; do
  [ -n "$line" ] || continue
  # $(INSTALL_BIN) ./files/usr/bin/tachyon-read $(1)/usr/bin/tachyon-read
  dest="${line##*\$(1)/}"
  [ "$dest" != "$line" ] || continue
  base="${dest##*/}"
  [ -n "$base" ] || continue
  checked=$((checked + 1))
  if ! printf '%s\n' "$chmod_targets" | grep -qxF "$base"; then
    missing=$((missing + 1))
    fail "build.sh does not chmod 0755 $base, so it ships non-executable: $dest"
  fi
done < <(grep -F '$(INSTALL_BIN)' "$MAKEFILE" || true)

[ "$checked" -gt 0 ] || fail "no \$(INSTALL_BIN) destinations parsed from the Makefile"

printf 'PASS: build.sh makes all %d Makefile executables executable\n' "$checked"