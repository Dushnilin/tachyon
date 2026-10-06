#!/usr/bin/env ucode

let validator = require("providers.nfqueue.validator");

const KIND = "nfqws";
const USAGE = "providers/zapret/validator.uc <validate|validate-json|strategy-or-default> <nfqws> <strategy> [legacy-default]";

function validate_strategy(kind, raw_opt, legacy_default) {
    return validator.validate_expected_strategy(KIND, kind, raw_opt, legacy_default);
}

function module_exports() {
    return {
        normalize_strategy_whitespace: validator.normalize_strategy_whitespace,
        strategy_or_default: validator.strategy_or_default,
        validate_strategy
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// Only run the CLI when a mode is actually named. config/validator.uc requires
// this module, and run_expected() ends in exit(1) for anything it does not
// recognise - an exit() from an imported module tears down the interpreter
// the caller is still running in, which shows up as heap corruption rather
// than an error. Being required with no arguments is not a CLI invocation.
if (length(ARGV) > 0)
    validator.run_expected(KIND, USAGE, ARGV);