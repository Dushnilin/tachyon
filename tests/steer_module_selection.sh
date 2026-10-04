#!/usr/bin/env bash
# steer 2.0.0 splits the engine into "steer-core" plus feature modules
# ("steer-obfs-...", "steer-tgws-...", ...), and "steer-extended" became an empty
# transition stub whose Depends on every module is exactly what used to fail the
# install. Tachyon therefore:
#   - resolves the core and each module out of ONE release, never the stub;
#   - honours tachyon.settings.steer_modules (absent = every module, "" = none);
#   - installs core + selection in one package transaction and removes modules
#     that are installed but not selected;
#   - reports the effective selection via system_info so the UI checkboxes and
#     the backend agree - same module list on both sides.
#
# A 1.x release carries no steer-core asset, so the legacy single-package path
# must still be reachable.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

CATALOG="$TACHYON_LIB/components/catalog.uc"
ACTION="$TACHYON_LIB/components/action.uc"
HELPERS="$TACHYON_LIB/components/helpers.uc"
SYSINFO="$TACHYON_LIB/diagnostics/system_info.uc"
FE_MOD="$ROOT_DIR/fe-app-tachyon/src/tachyon/tabs/updates/steerModules.ts"
FE_CARD="$ROOT_DIR/fe-app-tachyon/src/tachyon/tabs/updates/initController.ts"
FE_TYPES="$ROOT_DIR/fe-app-tachyon/src/tachyon/types.ts"
FE_STORE="$ROOT_DIR/fe-app-tachyon/src/tachyon/services/store.service.ts"
for f in "$CATALOG" "$ACTION" "$HELPERS" "$SYSINFO" "$FE_MOD" "$FE_CARD" "$FE_TYPES" "$FE_STORE"; do
  [ -f "$f" ] || fail "missing $f"
done
command -v ucode >/dev/null || fail "ucode is not on PATH"

# ---------------------------------------------------------------------------
# Behaviour: the parser, the selection semantics, the default module list.
# ---------------------------------------------------------------------------

cat >"$WORK_DIR/probe.uc" <<'UCODE'
let cat = require("components.catalog");

let suffix = "-1_aarch64_cortex-a53.apk";
let modular_body = sprintf("%J", {
    tag_name: "v2.0.0",
    html_url: "https://github.com/xyzmean/steer/releases/tag/v2.0.0",
    assets: [
        { name: "steer-core-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/core" },
        { name: "steer-core-2.0.0-1_x86_64.apk", browser_download_url: "u/core-x86" },
        { name: "steer-extended-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/stub" },
        { name: "steer-obfs-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/obfs" },
        { name: "steer-tgws-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/tgws" },
        { name: "steer-vless-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/vless" },
        { name: "steer-xsteer-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/xsteer" },
        { name: "steer-proxy-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/proxy" },
        { name: "steer-hysteria2-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/hy2" },
        { name: "steer-hub-aarch64.tar.gz", browser_download_url: "u/hub" },
        { name: "steer-futuremod-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/future" },
        { name: "luci-i18n-steer-ru-2.0.0-1_aarch64_cortex-a53.apk", browser_download_url: "u/i18n" }
    ]
});

let res = cat.steer_module_assets_from_release(modular_body, "aarch64_cortex-a53", suffix);
if (res == null) { print("parse=null\n"); exit(1); }
print("core=", res.core.package_name, "\n");
print("core_version=", res.version, "\n");
let names = [];
for (let m in res.modules) push(names, m.module);
print("modules=", join(",", names), "\n");

let legacy_body = sprintf("%J", {
    tag_name: "v1.9.5",
    html_url: "https://github.com/xyzmean/steer/releases/tag/v1.9.5",
    assets: [
        { name: "steer-1.9.5-1_aarch64_cortex-a53.apk", browser_download_url: "u/legacy" },
        { name: "steer-extended-1.9.5-1_aarch64_cortex-a53.apk", browser_download_url: "u/legext" }
    ]
});
let legacy = cat.steer_module_assets_from_release(legacy_body, "aarch64_cortex-a53", suffix);
print("legacy_modular=", legacy == null ? "null" : "not-null", "\n");

print("all_modules=", join(",", cat.steer_module_names()), "\n");
print("absent=", join(",", cat.steer_modules_from_settings({})), "\n");
print("empty=", length(cat.steer_modules_from_settings({ steer_modules: "" })), "\n");
print("strsel=", join(",", cat.steer_modules_from_settings({ steer_modules: "obfs tgws" })), "\n");
print("listsel=", join(",", cat.steer_modules_from_settings({ steer_modules: [ "vless" ] })), "\n");
UCODE

out="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/probe.uc" 2>/dev/null)" ||
  fail "the catalog probe itself failed to run"
printf '%s\n' "$out" >"$WORK_DIR/probe.out"

grep -qx 'core=steer-core-2.0.0-1_aarch64_cortex-a53.apk' "$WORK_DIR/probe.out" ||
  fail "the resolver did not pick the core package for this architecture: $(grep '^core=' "$WORK_DIR/probe.out")"
ok
grep -qx 'core_version=2.0.0' "$WORK_DIR/probe.out" ||
  fail "the core package version did not parse out of the asset name: $(grep '^core_version=' "$WORK_DIR/probe.out" || true) / probe said: $(tr '\n' ' ' <"$WORK_DIR/probe.out")"
ok
grep -qx 'modules=obfs,tgws,vless,xsteer,proxy,hysteria2' "$WORK_DIR/probe.out" ||
  fail "the module set is not exactly the known six (stub/hub/foreign assets leaked in): $(grep '^modules=' "$WORK_DIR/probe.out")"
ok
grep -qx 'legacy_modular=null' "$WORK_DIR/probe.out" ||
  fail "a 1.x release must not look modular, or the legacy path is unreachable"
ok
grep -qx 'all_modules=obfs,tgws,vless,xsteer,proxy,hysteria2' "$WORK_DIR/probe.out" ||
  fail "steer_module_names() must list every module the install can select"
ok
grep -qx 'absent=obfs,tgws,vless,xsteer,proxy,hysteria2' "$WORK_DIR/probe.out" ||
  fail "an absent steer_modules option must default to every module"
ok
grep -qx 'empty=0' "$WORK_DIR/probe.out" ||
  fail "an empty steer_modules value must mean no modules, not the default"
ok
grep -qx 'strsel=obfs,tgws' "$WORK_DIR/probe.out" ||
  fail "a space-separated steer_modules string must split into the selection"
ok
grep -qx 'listsel=vless' "$WORK_DIR/probe.out" ||
  fail "a real UCI list must survive the selection reader unchanged"
ok

# ---------------------------------------------------------------------------
# install_steer: resolve modular first, fall back to the legacy walk, read the
# selection, one transaction, remove what is not selected.
# ---------------------------------------------------------------------------

install_body="$(sed -n '/^function install_steer/,/^}/p' "$ACTION")"
[ -n "$install_body" ] || fail "install_steer not found"

grep -q 'modular = cmp_cat.resolve_steer_module_assets(arch, target_tag)' <<<"$install_body" ||
  fail "install_steer does not resolve the modular (core + modules) set"
ok
grep -q 'release = cmp_cat.resolve_steer_release(arch, target_tag, extended)' <<<"$install_body" ||
  fail "install_steer lost the legacy single-package fallback for 1.x releases"
ok
grep -q 'if (modular == null)' <<<"$install_body" ||
  fail "install_steer does not gate the legacy path on the modular resolve"
ok
grep -q 'if (modular != null)' <<<"$install_body" ||
  fail "install_steer does not gate the module selection on the modular resolve"
ok
grep -qF 'cmp_cat.steer_modules_from_settings(uci_core.get_all(TACHYON_CONFIG_NAME, "settings") || {})' <<<"$install_body" ||
  fail "install_steer does not read tachyon.settings.steer_modules"
ok
grep -q 'push(files, pkg.file)' <<<"$install_body" ||
  fail "the core package is not staged into the shared file list"
ok
grep -q 'push(files, mpkg.file)' <<<"$install_body" ||
  fail "selected modules are not staged into the shared file list"
ok
grep -qF 'run_logged_pkg_install_files("Installing " + label + " package " + pkg.name, files, PKG_INSTALL_TIMEOUT)' <<<"$install_body" ||
  fail "the install is not a single transaction over the whole file list"
ok
grep -q 'stale_pkg = "steer-" + m' <<<"$install_body" ||
  fail "modules outside the selection are never named for removal"
ok
grep -q 'pkg_is_installed(stale_pkg)' <<<"$install_body" ||
  fail "the removal loop does not check what is actually installed"
ok
grep -q 'run_logged_pkg_remove_sing_box_conflict(stale_pkg' <<<"$install_body" ||
  fail "an unselected installed module would stay on the router"
ok

# The package post-install enables and starts steerd on its own; only the
# active engine may keep it running, otherwise it survives next to sing-box.
grep -qF 'disable_standalone_service("steer")' <<<"$install_body" ||
  fail "install_steer does not stop the package-autostarted steer service"
ok
grep -q 'active_engine != engine.ENGINE_STEER' <<<"$install_body" ||
  fail "the standalone stop is not guarded by the active engine"
ok

# Downloads must be finished before anything destructive starts: a failed
# download must not leave the router without its engine.
last_download_line=$(grep -n 'download_direct_package(' <<<"$install_body" | tail -1 | cut -d: -f1)
first_conflict_line=$(grep -n 'let conflicts = ' <<<"$install_body" | head -1 | cut -d: -f1)
[ -n "$last_download_line" ] && [ -n "$first_conflict_line" ] ||
  fail "could not locate the download/conflict blocks in install_steer"
if [ "$last_download_line" -ge "$first_conflict_line" ]; then
  fail "packages are still being downloaded after the conflict removal starts (line $last_download_line >= $first_conflict_line)"
fi
ok

# ---------------------------------------------------------------------------
# system_info reports the effective selection; the APK world hygiene covers the
# new package names.
# ---------------------------------------------------------------------------

grep -qF 'steer_modules: cmp_cat.steer_modules_from_settings(settings())' "$SYSINFO" ||
  fail "system_info does not report the effective steer module selection"
ok

sanitize_body="$(sed -n '/^function sanitize_apk_world/,/^}/p' "$HELPERS")"
[ -n "$sanitize_body" ] || fail "sanitize_apk_world not found"
grep -qF 'steer-(obfs|tgws|vless|xsteer|proxy|hysteria2)' <<<"$sanitize_body" ||
  fail "apk world pin-stripping does not cover the steer module packages"
ok
grep -q '"steer-core"' <<<"$sanitize_body" ||
  fail "apk world hygiene does not know about the steer-core package"
ok

# ---------------------------------------------------------------------------
# Frontend parity: same module list, same defaults, wired to UCI + system_info.
# ---------------------------------------------------------------------------

fe_list="$(sed -n '/^export const STEER_MODULES = \[/,/^\] as const;/p' "$FE_MOD" |
  grep -oE "'[a-z0-9]+'" | tr -d "'" | tr '\n' ',' | sed 's/,$//')"
[ -n "$fe_list" ] || fail "could not read STEER_MODULES out of $FE_MOD"
backend_list="$(printf '%s\n' "$out" | sed -n 's/^all_modules=//p')"
[ "$fe_list" = "$backend_list" ] ||
  fail "the frontend module list ('$fe_list') drifted from the backend's ('$backend_list')"
ok

grep -qF "extended: ['obfs', 'tgws', 'vless', 'xsteer']" "$FE_MOD" ||
  fail "the Extended preset is not the four-module set it should be"
ok
grep -qF 'base: [],' "$FE_MOD" ||
  fail "the Base preset must select no modules"
ok
grep -qF "return [['-q', 'delete', 'tachyon.settings.steer_modules']]" "$FE_MOD" ||
  fail "the default selection is not written back by removing the option"
ok
grep -qF 'export function steerModulesUciArgs' "$FE_MOD" ||
  fail "steerModulesUciArgs is not the writer"
ok

grep -q 'normalizeSteerModules(systemInfo.steer_modules)' "$FE_CARD" ||
  fail "the engine card does not read the selection out of system_info"
ok
grep -q 'steerModulesUciArgs(selection)' "$FE_CARD" ||
  fail "the engine card never persists the selection"
ok
grep -qF "await TachyonShellMethods.uciRunCommand(['commit', 'tachyon'])" "$FE_CARD" ||
  fail "the engine card saves the selection without a uci commit"
ok
grep -q 'steer_modules?: string\[\];' "$FE_TYPES" ||
  fail "GetSystemInfo has no steer_modules field"
ok
grep -q 'steer_modules?: string\[\];' "$FE_STORE" ||
  fail "the store snapshot has no steer_modules field"
ok

printf 'steer module selection: %d checks passed\n' "$pass_count"
printf 'PASS: steer_module_selection\n'
