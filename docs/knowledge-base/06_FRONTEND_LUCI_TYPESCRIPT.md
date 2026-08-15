# 06. Frontend Architecture (LuCI & TypeScript)

## 1. Frontend Architecture Overview

Tachyon's web UI is authored as a single-page application in **TypeScript** under `fe-app-tachyon/` and compiled into a standalone JavaScript view under `luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/main.js`.

```
fe-app-tachyon/ (TypeScript Source)
       │
       ▼ (npm run build: tsc --noEmit && tsup)
       │
[tsup build + baseclass.extend transformation]
       │
       ▼
luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/main.js (LuCI Asset)
```

---

## 2. The LuCI `baseclass.extend()` Patch Mechanism

LuCI uses a custom asynchronous class system (`baseclass.extend({...})`) rather than standard ES modules or Webpack bundles.

* `fe-app-tachyon/tsup.config.ts` compiles the TypeScript entry point (`src/main.ts`) into an ES module.
* A custom post-processing step inside `tsup.config.ts` transforms the compiled file:
  1. Strips ESM `export default` statements.
  2. Wraps the controller inside LuCI's expected `return baseclass.extend({...})` pattern.
  3. Injects global LuCI helper references (`ui`, `rpc`, `uci`, `fs`, `_`).

> [!IMPORTANT]
> **Do not attempt to convert `main.js` back into a standard ES module export.** This LuCI bridge is intentional and strictly required for compatibility with all OpenWrt web themes (Bootstrap, Material, Argon, OpenWrt-Two).

---

## 3. Reactive State Management & Services

The frontend does not use heavy external frameworks (like React or Vue) to keep package size minimal ($\approx$ 500 KB uncompressed, $\approx$ 90 KB gzipped). Instead, it uses lightweight TypeScript observable stores:

### 3.1. Key Services (`src/tachyon/services/`)

| Service | File | Purpose |
|---|---|---|
| `StoreService` | `store.service.ts` | Central reactive data store with subscription listeners. |
| `UiStateService` | `uiState.service.ts` | Tracks UI view state, tab switching, and modal states. |
| `RuntimeUiStateService`| `runtimeUiState.service.ts`| Polling and caching of backend service metrics and active jobs. |
| `SocketService` | `socket.service.ts` | WebSocket client for real-time log streaming when available. |
| `TachyonLogWatcher` | `tachyonLogWatcher.service.ts`| Logread stream deduplication and notification dispatcher. |

---

## 4. Tabs & UI View Structure

```
src/tachyon/tabs/
├── dashboard/        # Live status, RTT ping matrix, traffic toggles
├── diagnostic/       # AI Doctor modal, Local Rule Doctor, Emergency Fallback
├── rules/            # Selective routing rules, domain/IP lists, client matchers
├── providers/        # Zapret v1, Zapret v2, ByeDPI configurations
├── updates/          # Component installer, version checks, streaming log modal
└── settings/         # DNS settings, Telegram bot credentials, AI Doctor API keys
```

### 4.1. The Updates & Installation Modal (`renderUpdateProgressModal.ts`)
* Provides a streaming log console that polls `/usr/bin/tachyon` output asynchronously via `componentActionLog(jobId, offset)`.
* Features:
  * Non-blocking operation: router performs installation in background.
  * Real-time timer and progress badge.
  * Preserves output logs and green success/red error banners.
  * Prevents premature auto-close so users can inspect package manager details.
  * Graceful countdown timer for Tachyon package reloads.
