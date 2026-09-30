#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
node "$root/tests/smart_detect_modes_ui.mjs"
