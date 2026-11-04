// Keep the routing tracer independent of the full diagnostics module graph.
// The cache reader still validates the configured list and its loaded revision.
let cache = require("diagnostics.ruleset_cache");

if (ARGV[0] != "extract-ruleset") {
    warn("Unknown rule-set inspection command\n");
    exit(1);
}

try {
    print(cache.extract(ARGV[1] || "") + "\n");
    exit(0);
}
catch (e) {
    warn("Cannot inspect configured rule-set: ", e, "\n");
    exit(1);
}
