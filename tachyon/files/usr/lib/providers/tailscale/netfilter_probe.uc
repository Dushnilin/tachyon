#!/usr/bin/env ucode
//
// Capability probe for --netfilter-mode, kept apart from providers/tailscale/runtime.uc
// so it can be exercised directly. runtime.uc is a script: requiring it runs its CLI
// dispatcher, which prints usage and exits.
//

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let command_output = common.command_output;
let command_from_args = common.command_from_args;

const TAILSCALE_BIN = getenv("TAILSCALE_BIN") || "/usr/sbin/tailscale";
const TAILSCALED_BIN = getenv("TAILSCALED_BIN") || "/usr/sbin/tailscaled";

/**
 * Does this binary document --netfilter-mode?
 *
 * `tailscale up` with no arguments is not a help query - it is the command that
 * connects or changes preferences. It used to be run as the probe, so asking whether
 * a flag exists could itself bring the client up or rewrite its settings. It also
 * read the wrong text: on 1.98.3 the flag is declared by `tailscale up --help` and
 * not by the general `tailscale --help`, so the client was never given the flag,
 * tailscaled installed its own netfilter rules, and the router ended up carrying ip
 * filter / nat / mangle tables that the diagnostics then reported as foreign marking
 * rules.
 *
 * tailscaled is a daemon, so plain --help is the help query there.
 */
function netfilter_help_has_flag(bin) {
    if (!bin || fs.stat(bin) == null) return false;

    // No fallback to the general help: it is a different question, and on a client
    // that documents the flag under "up --help" it answers no. The old fallback
    // keyed off the word "up" appearing in the output, which a help text need not
    // contain, so it replaced a correct answer with a wrong one.
    //
    // OpenWrt 1.98.3 prints that help on stderr (Go flag package), and
    // command_output_from_args() redirects stderr to /dev/null by design - it read
    // an empty text and answered no (#110). Both streams are read here, the same
    // way nfqws_blob_is_builtin() asks its binary, and nowhere else.
    let help = command_output(command_from_args(
        bin == TAILSCALE_BIN ? [ bin, "up", "--help" ] : [ bin, "--help" ]
    ) + " 2>&1");

    return index(as_string(help), "netfilter-mode") >= 0;
}

let _supported_daemon = null;
let _supported_client = null;

function netfilter_mode_supported_by_daemon() {
    if (_supported_daemon === null)
        _supported_daemon = netfilter_help_has_flag(TAILSCALED_BIN);
    return _supported_daemon;
}

function netfilter_mode_supported_by_client() {
    if (_supported_client === null)
        _supported_client = netfilter_help_has_flag(TAILSCALE_BIN);
    return _supported_client;
}

function module_exports() {
    return {
        TAILSCALE_BIN,
        TAILSCALED_BIN,
        netfilter_help_has_flag,
        netfilter_mode_supported_by_client,
        netfilter_mode_supported_by_daemon
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: providers/tailscale/netfilter_probe.uc (library module, no CLI)\n");
exit(1);