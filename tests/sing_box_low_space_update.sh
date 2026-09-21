#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'function move_validated_file_to_backup_or_discard(target_path, backup_path, label)' "$ACTION_UC" ||
  fail "validated low-space backup fallback helper is missing"
grep -Fq 'if (get_component_backup_enabled())' "$ACTION_UC" ||
  fail "low-space fallback must remain disabled when persistent component backups are requested"
grep -Fq 'component backups are disabled, removing the current file to free space for the validated replacement' "$ACTION_UC" ||
  fail "low-space fallback must leave an explicit warning in the update log"

usage_count="$(grep -Fc 'backup_binary = move_validated_file_to_backup_or_discard(' "$ACTION_UC")"
[ "$usage_count" -eq 2 ] ||
  fail "validated low-space fallback must be used by compressed extended and lx installs"

assert_validated_before_fallback() {
  local start="$1"
  local end="$2"
  local block validate_line fallback_line
  block="$(awk -v start="$start" -v end="$end" '
    index($0, start) { inside=1 }
    inside && index($0, end) { exit }
    inside { print }
  ' "$ACTION_UC")"
  validate_line="$(printf '%s\n' "$block" | grep -n -m1 'validate_sing_box_extended_binary(tmp_binary' | cut -d: -f1 || true)"
  fallback_line="$(printf '%s\n' "$block" | grep -n -m1 'backup_binary = move_validated_file_to_backup_or_discard(' | cut -d: -f1 || true)"
  [ -n "$validate_line" ] || fail "$start does not validate the downloaded binary"
  [ -n "$fallback_line" ] || fail "$start does not use the low-space fallback"
  [ "$validate_line" -lt "$fallback_line" ] ||
    fail "$start must validate the replacement before discarding the current binary"
}

assert_validated_before_fallback 'function install_sing_box_extended(action, compressed, target_tag)' 'function install_sing_box_lx(action, target_tag)'
assert_validated_before_fallback 'function install_sing_box_lx(action, target_tag)' 'function install_package_sing_box(action, tiny)'

printf 'sing-box low-space update policy tests passed\n'
