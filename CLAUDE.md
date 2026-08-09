# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpenWrt package for proxy / anti-censorship orchestration (sing-box + zapret v1/v2 + ByeDPI + Telegram bot + self-healing watchdog). Fork of Forkop / Podkop Plus. Ships two packages: `tachyon` (backend, ucode) and `luci-app-tachyon` (web UI).

Backend logic is **ucode** — OpenWrt's native scripting language. Not Lua, not JS. Frontend is TypeScript compiled into LuCI-style JS.

## Commands

### Backend tests

No ucode toolchain on the Windows host. Everything runs in the container built from `tests/Dockerfile.test` (tag `tachyon-ucode:test`, ucode v0.0.20250529, built with `-DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DULOOP_SUPPORT=OFF`).

Build the image once, then run through PowerShell (Git-Bash mangles the `-v G:/tachyon:/repo` path) and append `exit $LASTEXITCODE` so an inner failure actually surfaces:

```powershell
docker build -t tachyon-ucode:test -f tests/Dockerfile.test tests
docker run --rm -v 'G:/tachyon:/repo' -w /repo tachyon-ucode:test bash -c 'bash tests/run_all.sh'; exit $LASTEXITCODE
docker run --rm -v 'G:/tachyon:/repo' -w /repo tachyon-ucode:test bash -c 'bash tests/event_bus.sh'; exit $LASTEXITCODE
```

- `tests/run_all.sh` = syntax lint + every `tests/*.sh` serially. Auto-discovers; new tests need no registration.
- `tests/ucode_syntax_lint.sh` = compile check only (`ucode -c` and `ucode -S -c` over every `.uc`).
- `docker_e2e_test.sh` and `container_entrypoint.sh` are excluded from `run_all.sh` — they need Docker themselves.
- CI (`.github/workflows/backend-ci.yml`) runs the same set with `xargs -P4`.

Container gotchas: `ucode -e '...'` combined with `-L` aborts with `double free or corruption` — write snippets to a real `.uc` file. No `python3`; use `sed`/`perl`. `mktemp --suffix` unsupported.

### Frontend

```bash
cd fe-app-tachyon
npm install          # npm, not yarn (package-lock.json is authoritative)
npm run build        # tsc --noEmit, then tsup
npm test             # vitest
npm run ci           # format + lint + test --run + build
npm run locales:actualize   # extract calls -> pot -> ru po -> distribute
```

### Package build

```bash
bash build.sh <x.y.z> [output-dir]
```

Requires Linux + apt (auto-installs deps); on WSL the repo is copied to the native FS first. Version must be semver or the script exits. Output lands in `dist/release-final/` as `.ipk` + `.apk`.

### Lint

```bash
shellcheck --severity=error build.sh install.sh tachyon/files/etc/init.d/* luci-app-tachyon/root/etc/uci-defaults/* tests/**/*.sh
cd fe-app-tachyon && npm run lint
```

## Architecture

### Backend: ucode module tree

All modules live under `tachyon/files/usr/lib/`, installed to `/usr/lib/tachyon/`. Loaded via `ucode -L <lib_dir>` with dotted requires that mirror the directory layout: `require("core.uci")` → `core/uci.uc`, `require("providers.zapret.runtime")` → `providers/zapret/runtime.uc`.

Layers, roughly bottom-up:

- `core/` — no domain knowledge. `common` (string/shell helpers), `uci` (config read/write), `helpers` (tag naming, file predicates), `ip`, `url`, `constants`, `packages`, `events` (the bus).
- `config/` — UCI schema layer: `validator`, `migration` (forkop/podkop → tachyon), `rule`, `domain`, `connections`.
- `singbox/` — config generation. `generator` orchestrates, with `generator_outbounds` / `generator_routes` / `route` / `dns*` / `country` / `priority` as parts.
- `providers/` — one subtree per DPI-bypass engine (`zapret`, `zapret2`, `nfqueue`, `byedpi`), each with the same `runtime` / `validator` / `check` triad, plus shared `rules.uc` and `status.uc`.
- `service/` — lifecycle and orchestration: `initd` (called by `/etc/init.d/tachyon`), `lifecycle`, `reload`, `state`, `api`, `telegram`, `ui`, `watchdog`, `event_controller`, `package`.
- `nft/`, `dns/`, `routing/`, `diagnostics/`, `subscription/`, `components/`, `server/` — focused single-concern modules.

Every module is **both a library and a CLI**. The bottom of each `.uc` file is an `if (mode == "...")` dispatch chain over `ARGV`, which is how the shell tests exercise pure functions:

```bash
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/core/helpers.uc" outbound-tag proxy   # -> proxy-out
```

When adding a function you want tested, add a dispatch arm for it — that is the established test seam.

### Event bus, not timers

`core/events.uc` is a domain-agnostic pub/sub bus (per-subscriber cooldown, publish-side dedup, priority ordering, handler error isolation, `clock(true)` monotonic timing so NTP steps at boot don't skew windows). It performs no I/O, which is what makes it unit-testable.

The strict split around it:

- `service/event_controller.uc` **observes only** — push sources (ubus, syslog, honeypot FIFO) and probe tiers (fast 15s / normal adaptive 120–300s / slow 300s) turn system state into facts on the bus. Event names live in an `EV` constant table so a typo is a load-time error.
- `service/watchdog.uc` **repairs only** — subscribes to those facts. Its registrations go through a `subscribe()` wrapper that `die()`s if `bus.on()` rejects the handler (see the hoisting hazard below).

Do not add probing to a healer or repair to the controller.

### Entrypoints

- `/usr/bin/tachyon` (`tachyon/files/usr/bin/tachyon`) — ucode CLI dispatcher. Resolves the module for a subcommand, shells out with `ucode -L`, normalizes the exit status, and restores the dnsmasq failsafe if the loader fails on a lifecycle command.
- `/etc/init.d/tachyon` — thin procd shim; delegates every action to `service/initd.uc`. Deliberately minimal shell.
- Environment overrides everywhere: `TACHYON_LIB`, `TACHYON_CONFIG_NAME`, `TACHYON_BIN`, `TACHYON_SERVICE_INIT`, plus per-module `SB_*` tag overrides. Tests rely on these — keep new constants overridable via `getenv(...) || default`.

### Frontend

`fe-app-tachyon/src/` → tsup → `luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/main.js`. The tsup `onSuccess` hook rewrites the emitted `export { ... }` into `return baseclass.extend({ ... })`, and **throws if that block is absent** — this is intentional LuCI interop, not a bug to fix. Anything the LuCI views need must be re-exported from `src/main.ts`.

`main.js` is generated — never edit it directly. The sibling files in that directory (`dashboard.js`, `settings.js`, `section.js`, …) are hand-written LuCI views that consume `main.js`.

`__COMPILED_VERSION_VARIABLE__` in `src/constants.ts` is a literal placeholder sed-replaced at build time. Leave it alone.

## Landmines

**ucode does not hoist function declarations.** Not at file scope, not nested. A name used before its declaration resolves as a global and comes back `null`. It's lexical, not timing — a closure created before a sibling `function` is declared never captures it, so deferring the call doesn't help. Both `ucode -c` and `ucode -S -c` accept the broken file; you get a runtime `Type error: left-hand side is not a function`. Combined with the bus this fails silently: `bus.on()` returns `false` for a non-function handler, so a misordered handler registers nothing, emits nothing, throws nothing, and a repair just quietly stops happening. Guards: `tests/forward_references.sh` (static decl-after-use scan + actually invoking the push handlers) and `tests/watchdog_subscriptions.sh`.

**Contract tests exist and will fail you.** `package_contract.sh` checks `tachyon/Makefile` `DEPENDS` against what the code actually invokes; `shell_inventory.sh` fails if any `.sh` reappears under `tachyon/files/usr/lib/` (the runtime is ucode-only — a shell owner returning is a regression); `config_contract_matrix.sh` pins the UCI schema. Adding a new external binary or config option means updating the matching contract.

**Atomic writes.** JSON configs, subscription cache, diagnostics, runtime state, and UCI backups all go through tmp + `mv`. Persistent staging lives in `/etc/.tachyon/` so it survives reboot. Follow this when writing new state.

**`/etc/config/tachyon` must be `chmod 600` root:root** — it holds the Telegram bot token. postinst/postupgrade re-assert this; so should any code that rewrites the file.

**postupgrade is deliberately violent.** It kills the procd `flock`-waiting processes before starting via `/usr/bin/tachyon start` (which registers with procd directly), because `rc.common`'s `flock -w 1000` plus `retry_start_on_wan_up` retriggers deadlocks across an upgrade. Read the comment in `tachyon/Makefile` before touching it.

**Line endings: LF, enforced by `.gitattributes`.** Never commit CRLF from Windows.

**Legacy migration is a supported path** — configs from `forkop`, `forkop_plus`, and `podkop` are migrated in postinst and `config/migration.uc`. Don't drop those code paths.

## Conventions

- Each shell test is standalone: `set -eo pipefail`, a local `ucode()` wrapper that injects `-L "$TACHYON_LIB"`, `fail()`/`assert_eq()` helpers, exit non-zero on mismatch. No framework, no shared harness beyond `tests/helpers/`.
- Branches: `main` for releases, `rc/**` for release candidates.
- Backend CI only triggers on `tachyon/files/**`, `tachyon/Makefile`, `build.sh`, `tests/**` — a frontend-only change won't run it.
