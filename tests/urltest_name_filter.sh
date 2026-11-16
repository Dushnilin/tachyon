#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ucode -L "$TACHYON_LIB" -e '
let urltest = require("tachyon_core.urltest");
let samples = [
    "", "0", 0, "Berlin", "berlin", "Berlin (DE)", "Berlin [VLESS]",
    "🇩🇪 Берлин [5 GB left]", "🇩🇪 Берлин [3,5 GB left]",
    "[Подписка] Берлин [VLESS]", "Берлин: остаток 2 ГБ",
    "Berlin  Edge", "Berlin\tEdge", "A\x00B", "A\x00C"
];
let seed = 407;
for (let i = 0; i < 128; i++) {
    let names = [];
    for (let j = 0; j < i % 11; j++) {
        seed = (seed * 48271) % 2147483647;
        push(names, samples[seed % length(samples)]);
    }
    let lookup = urltest.prepare_name_filter(names);
    for (let candidate in samples) {
        let expected = urltest.name_filter_contains(names, candidate);
        if (expected != (lookup != null && lookup(candidate)))
            die(sprintf("name filter mismatch for %J in %J\n", candidate, names));
    }
}
let tags = ["kept", "case", "by_tag", "blocked"];
let names = { kept: "Berlin [5 GB left]", case: "berlin", by_tag: "Paris",
    blocked: "Berlin [6 GB left]" };
let selected = urltest.filter_mode("mixed", tags, names, {}, ["Berlin [9 GB left]", "by_tag"],
    [], [], [], ["6 GB"], []);
if (join(",", selected) != "kept,by_tag")
    die(sprintf("unexpected filter output %J\n", selected));
'
