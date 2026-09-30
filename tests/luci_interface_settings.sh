#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SECTION_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"

grep -Fq 'function dnsTypeChoices() {' "$SECTION_JS" ||
  fail "network interface settings must define DNS protocol choices"
grep -Fq 'dnsTypeChoices().forEach((choice) => o.value(choice.value, choice.label));' "$SECTION_JS" ||
  fail "network interface settings must populate the DNS protocol field"
grep -Fq 'o.renderItemSettingsModal = showInterfaceSettingsModal;' "$SECTION_JS" ||
  fail "network interfaces must keep their settings modal handler"

printf 'LuCI network interface settings checks passed\n'
