#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "${BASH_SOURCE[0]}")/smart_detect_exclusion_lists_ui.mjs"
