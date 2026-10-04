#!/usr/bin/env ucode
//
// Telling a broken sing-box apart from a broken configuration.
//
// Separate from singbox/runtime.uc because that file is a script: requiring it runs
// its CLI dispatcher. Both helpers are small and pure apart from the stat/open, and
// the difference between the two failures is worth being able to test directly - it
// is the difference between a user fixing their config and a user fixing their
// router.
//

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;

/**
 * Why the binary could not be used, or "" when the file looks like a binary.
 *
 * Empty, missing and script-in-place-of-a-binary all come back from a config check as
 * a failure with no usable detail. The shell's own error arrives prefixed with the
 * binary path, so the message reads like a configuration problem when it is not.
 */
function sing_box_binary_problem(path) {
    path = as_string(path);
    let info = fs.stat(path);
    if (info == null)
        return "sing-box binary is missing at " + path;
    if (int(info.size || 0) <= 0)
        return "sing-box binary at " + path + " is empty";

    // A shebang means something is being executed in its place - a wrapper, a
    // half-extracted stub, a failed upgrade - and it is not the engine.
    let head = "";
    try {
        let file = fs.open(path, "r");
        if (file) {
            head = as_string(file.read(256));
            file.close();
        }
    } catch (e) {}

    if (substr(head, 0, 2) == "#!")
        return "sing-box at " + path +
            " is a shell script, not the sing-box binary - the variant is broken or something replaced it with a wrapper";

    return "";
}

/**
 * True when the check output is the shell complaining about the binary rather than
 * sing-box complaining about the configuration.
 *
 * Deliberately conservative: a bare exit status carries no evidence at all, and
 * guessing from one would blame the binary for ordinary config errors.
 */
function sing_box_check_blamed_the_binary(reason) {
    let text = as_string(reason || "");
    if (text == "") return false;
    // The shell's shape is "<path>: line <N>: <message>". The space and the word
    // "line" are part of it - matching only ":<digits>:" missed every real report.
    if (match(text, /:[ \t]*line[ \t]+[0-9]+:/i) != null) return true;
    if (match(text, /:(syntax error|unexpected word)/i) != null) return true;
    if (match(text, /(Permission denied|Exec format error|Text file busy|No such file or directory)/i) != null) return true;
    return false;
}

function module_exports() {
    return {
        sing_box_binary_problem,
        sing_box_check_blamed_the_binary
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: singbox/binary_diag.uc (library module, no CLI)\n");
exit(1);