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

// trim() is a ucode builtin; common does not export it.
let as_string = common.as_string;

/**
 * Why the binary could not be used, or "" when the file looks like a binary.
 *
 * Empty, missing and script-in-place-of-a-binary all come back from a config check as
 * a failure with no usable detail. The shell's own error arrives prefixed with the
 * binary path, so the message reads like a configuration problem when it is not.
 */
function sing_box_binary_problem(path) {
    // The path can arrive straight from `command -v` with its trailing newline, and
    // a stat of "/usr/bin/sing-box\n" fails on a file that is very much there —
    // which reported a perfectly present binary as missing.
    path = trim(as_string(path));
    if (path == "")
        return "sing-box binary path is empty";
    let info = fs.stat(path);
    if (info == null)
        return "sing-box binary is missing at " + path;
    if (int(info.size || 0) <= 0)
        return "sing-box binary at " + path + " is empty";

    let head = "";
    try {
        let file = fs.open(path, "r");
        if (file) {
            head = as_string(file.read(256));
            file.close();
        }
    } catch (e) {}

    // A Mach-O file has no shebang and looks like any other binary to `stat`, so
    // nothing short of the magic bytes says what went wrong: the kernel refuses to
    // exec it, the shell reads it as a script, and the error arrives as a shell
    // syntax error on "line N" - pointing at a configuration nobody has touched.
    //
    // The magic is compared numerically: ucode's "\xcf" escapes become UTF-8
    // (two bytes), never the single byte on disk.
    let head4 = substr(head, 0, 4);
    let is_macho = false;
    if (length(head4) == 4) {
        let b0 = ord(substr(head4, 0, 1));
        let b1 = ord(substr(head4, 1, 1));
        let b2 = ord(substr(head4, 2, 1));
        let b3 = ord(substr(head4, 3, 1));
        is_macho =
            (b0 == 0xcf && b1 == 0xfa && b2 == 0xed && b3 == 0xfe) ||  // MH_MAGIC_64
            (b0 == 0xfe && b1 == 0xed && b2 == 0xfa && b3 == 0xcf) ||  // MH_CIGAM_64
            (b0 == 0xce && b1 == 0xfa && b2 == 0xed && b3 == 0xfe) ||  // MH_MAGIC
            (b0 == 0xfe && b1 == 0xed && b2 == 0xfa && b3 == 0xce) ||  // MH_CIGAM
            (b0 == 0xca && b1 == 0xfe && b2 == 0xba && b3 == 0xbe) ||  // FAT_MAGIC
            (b0 == 0xbe && b1 == 0xba && b2 == 0xfe && b3 == 0xca);    // FAT_CIGAM
    }
    if (is_macho)
        return "sing-box at " + path +
            " is a macOS (Mach-O) build, not a Linux binary - a binary for another operating system was installed in its place. Reinstall the sing-box variant to get the correct build.";

    // A shebang means something is being executed in its place - a wrapper, a
    // half-extracted stub, a failed upgrade - and it is not the engine.
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

return module_exports();
