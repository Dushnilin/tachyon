#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

wrapper_styles="$(sed -n '/^\.fkp-button-add-dynlist > \.add-item {$/,/^}$/p' "$SECTION_JS")"
button_styles="$(sed -n '/^\.fkp-button-add-dynlist > \.add-item > \.cbi-button-add {$/,/^}$/p' "$SECTION_JS")"

grep -Fq 'display: flex;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList add rows must use a content-sized flex wrapper"
grep -Fq 'width: var(--fkp-button-add-width, 210px);' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must follow the measured button width"
grep -Fq 'max-width: 100%;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must stay inside narrow option fields"
grep -Fq 'background: transparent;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must not render as empty input groups"
grep -Fq 'border: 0;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must leave framing to the button"

grep -Fq 'width: 100% !important;' <<<"$button_styles" ||
  fail "button-only DynamicList buttons must fill their content-sized wrapper"
grep -Fq 'max-width: 100% !important;' <<<"$button_styles" ||
  fail "button-only DynamicList buttons must not overflow narrow wrappers"
grep -Fq 'text-overflow: ellipsis !important;' <<<"$button_styles" ||
  fail "button-only DynamicList labels must truncate instead of overflowing"

printf 'LuCI DynamicList layout checks passed\n'
