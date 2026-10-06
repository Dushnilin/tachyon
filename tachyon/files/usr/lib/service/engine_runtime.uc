#!/usr/bin/env ucode
//
// service/engine_runtime.uc - CLI entry point for the engine runtime.
//
// This file dispatches and nothing else. The implementation is in
// service/engine_runtime_lib.uc, which is requireable and never exits.
//
// The split is deliberate. This module used to be both, guarded by a
// "was I required?" test. That test cannot be written correctly: sourcepath(1)
// is the *caller's* path, and it is null both when this file is the program
// ucode was told to run and when it is imported from `ucode -e` - so the two
// cases are indistinguishable. Production code does require this module
// (components/action.uc to switch engines, diagnostics/system_info.uc to read
// status), so it ran main() with the ambient ARGV and then exited the
// interpreter on the way out.
//
// The CLI paths that shell out to this file - the /usr/bin/tachyon dispatcher,
// diagnostics/doctor.uc, diagnostics/routing.uc - are unchanged, because this
// file still speaks the same subcommands.
//
let engine_runtime = require("service.engine_runtime_lib");

exit(engine_runtime.main(ARGV));
