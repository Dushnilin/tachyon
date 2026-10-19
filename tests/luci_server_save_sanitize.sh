#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SERVER_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/server.js"

node - "$SERVER_JS" <<'NODE'
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync(process.argv[2], "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

// The test container's node predates optional chaining (?.), so navigate the
// deletes object with plain guarded access.
function deletesFor(pkg, section) {
  const d = sandboxDeletes();
  if (!d || !d[pkg]) return undefined;
  if (section === undefined) return d[pkg];
  return d[pkg][section];
}
function sandboxDeletes() {
  return sandbox.uci && sandbox.uci.state ? sandbox.uci.state.deletes : undefined;
}

// The container's node (v12) predates optional chaining, but the production
// view code legitimately uses it (LuCI's browser supports it). This block only
// uses the `a?.[b]` form, so lower it to `a[b]` before running; every fixture
// below defines these objects, so the guard is never actually needed here.
function lowerOptionalChaining(code) {
  return code.replace(
    /([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\?\.\[/g,
    "$1[",
  );
}

function requiredIndex(needle, from = 0) {
  const index = source.indexOf(needle, from);
  if (index < 0) fail(`missing source contract: ${needle}`);
  return index;
}

// 1. Static Contract Checks
const sanitizeIdx = requiredIndex("function sanitizeUciDeletes(targetSectionId)");
const sanitizeBlock = source.slice(
  sanitizeIdx,
  source.indexOf("function ensureProtocolDefaults", sanitizeIdx),
);

if (
  !sanitizeBlock.includes("creates[sid] || !values[sid]") ||
  !sanitizeBlock.includes("delete deletes[sid]")
) {
  fail("sanitizeUciDeletes must delete entries for sections in creates or missing from values");
}

if (!sanitizeBlock.includes("!values[sid].hasOwnProperty(opt)")) {
  fail("sanitizeUciDeletes must prune deletes for options not existing in UCI values");
}

const renderModalIdx = requiredIndex("sectionRef.renderMoreOptionsModal = function");
const renderModalBlock = source.slice(
  renderModalIdx,
  source.indexOf("sectionRef.handleAdd = function", renderModalIdx),
);
if (!renderModalBlock.includes("sanitizeUciDeletes(sectionId)")) {
  fail("renderMoreOptionsModal must sanitize UCI deletes for sectionId");
}

const handleAddIdx = requiredIndex("sectionRef.handleAdd = function");
const handleAddBlock = source.slice(
  handleAddIdx,
  source.indexOf("sectionRef.handleModalCancel = function", handleAddIdx),
);
if (!handleAddBlock.includes("sanitizeUciDeletes(sectionId)")) {
  fail("handleAdd must sanitize UCI deletes when adding a new section");
}

const cancelIdx = requiredIndex("sectionRef.handleModalCancel = function");
const cancelBlock = source.slice(
  cancelIdx,
  source.indexOf("sectionRef.handleModalSave = function", cancelIdx),
);
if (!cancelBlock.includes("sanitizeUciDeletes(sectionId)")) {
  fail("handleModalCancel must sanitize UCI deletes on cancel");
}

const saveIdx = requiredIndex("sectionRef.handleModalSave = function");
const saveBlock = source.slice(
  saveIdx,
  source.indexOf("sectionRef.renderRowActions = function", saveIdx),
);

if (
  !saveBlock.includes("sanitizeUciDeletes(targetSectionId)") ||
  !saveBlock.includes("targetMap.save(beforeUciSave, true)")
) {
  fail("handleModalSave must sanitize deletes and pass beforeUciSave callback to targetMap.save");
}

if (
  !saveBlock.includes("const origCallDelete = uci.callDelete") ||
  !saveBlock.includes("ubus code 4") ||
  !saveBlock.includes("uci.callDelete = origCallDelete")
) {
  fail("handleModalSave must wrap uci.callDelete with fallback guard for code 4 and restore in finally");
}

// 2. Behavioral Verification of sanitizeUciDeletes
const sandbox = {
  console,
  UCI_PACKAGE: "tachyon",
  uci: {
    state: {},
  },
  isEmptyObject: function (val) {
    return val && Object.keys(val).length === 0;
  },
};

const sanitizeScript = new vm.Script(`
  ${lowerOptionalChaining(sanitizeBlock)}
  globalThis.sanitizeUciDeletes = sanitizeUciDeletes;
`);
const context = vm.createContext(sandbox);
sanitizeScript.runInContext(context);

// Scenario A: New section (e.g. SOCKS server) in creates with orphan deletes
sandbox.uci.state = {
  creates: {
    tachyon: {
      telegram_socks: { ".type": "server", ".name": "telegram_socks", protocol: "socks" },
    },
  },
  values: {
    tachyon: {
      main: { ".type": "main" },
    },
  },
  deletes: {
    tachyon: {
      telegram_socks: {
        vless_flow: true,
        server_uuid: true,
        tls_cert_path: true,
      },
    },
  },
};

sandbox.sanitizeUciDeletes("telegram_socks");

if (deletesFor("tachyon", "telegram_socks")) {
  fail("sanitizeUciDeletes must prune all deletes for newly created section");
}
if (deletesFor("tachyon")) {
  fail("sanitizeUciDeletes must prune empty package delete container");
}

// Scenario B: Existing section has deletes for options that do not exist in UCI values
sandbox.uci.state = {
  creates: {},
  values: {
    tachyon: {
      srv_existing: {
        ".type": "server",
        ".name": "srv_existing",
        protocol: "vless",
        server_uuid: "existing-uuid",
      },
    },
  },
  deletes: {
    tachyon: {
      srv_existing: {
        server_uuid: true,
        vless_flow: true,
        reality_public_key: true,
      },
      ghost_section: true,
    },
  },
};

sandbox.sanitizeUciDeletes("srv_existing");

const existingDeletes = deletesFor("tachyon", "srv_existing");
if (!existingDeletes || !existingDeletes.server_uuid) {
  fail("sanitizeUciDeletes must retain deletes for options that exist in UCI values");
}
if (existingDeletes.vless_flow || existingDeletes.reality_public_key) {
  fail("sanitizeUciDeletes must prune deletes for options not present in UCI values");
}
if (deletesFor("tachyon", "ghost_section")) {
  fail("sanitizeUciDeletes must prune deletes for non-existent sections");
}

NODE

printf "LuCI server save delete sanitization checks passed\n"
