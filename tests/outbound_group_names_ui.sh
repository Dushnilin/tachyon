#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "${BASH_SOURCE[0]}")/outbound_group_names_ui.mjs"
