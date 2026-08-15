# Tachyon Knowledge Base & Architecture Index

Welcome to the comprehensive technical knowledge base for **Tachyon**. This directory contains deep architectural specifications, module references, packet flow maps, and developer guidelines compiled directly from the codebase.

---

## 📚 Knowledge Base Table of Contents

| Document | Description | Key Topics Covered |
|---|---|---|
| [**01. System Architecture**](01_SYSTEM_ARCHITECTURE.md) | High-level system architecture & control plane | ucode runtime, atomic writes, repository layout, daemon lifecycle |
| [**02. ucode Module Reference**](02_UCODE_MODULE_REFERENCE.md) | Comprehensive reference for all 60+ `.uc` files | `core/`, `service/`, `diagnostics/`, `singbox/`, `providers/`, `nft/`, `dns/` |
| [**03. Networking & nftables**](03_NETWORKING_NFTABLES_AND_ROUTING.md) | Packet lifecycle, firewall tables & DNS routing | `inet TachyonTable`, fwmark bitmasks, TProxy, bootstrap DNS loops |
| [**04. DPI Bypass Engines**](04_DPI_BYPASS_ENGINES.md) | Local packet desynchronization deep dive | Zapret v1 (`nfqws`), Zapret v2 (`nfqws2`), ByeDPI (`ciadpi`), multisplit, seqovl |
| [**05. AI Stack & AI Doctor**](05_AI_STACK_AND_AUTONOMOUS_DOCTOR.md) | AI Doctor v2.5, Watchdog & REST Agent API | 13 Quick Fixes, Local Rule Doctor, NTP/MTU tuning, OpenAPI 3.0.3, REST API |
| [**06. Frontend LuCI Architecture**](06_FRONTEND_LUCI_TYPESCRIPT.md) | TypeScript SPA & LuCI view integration | `baseclass.extend` patch, reactive stores, live log streaming modal |
| [**07. Build & Testing Pipeline**](07_BUILD_TESTS_AND_DEPLOYMENT.md) | Compilation, testing & release workflows | `build.sh` (ipk/apk), `install.sh`, Docker CI container, vitest tests |

---

## ⚡ Quick Operational Cheat Sheet

### Common CLI Commands
```sh
# Diagnostics & AI
tachyon doctor                          # Local offline rule diagnostics
tachyon ai_doctor                       # AI Doctor LLM analysis
tachyon apply_quick_fix <code1,code2>   # Apply automated repair codes
tachyon restore_native_internet         # 1-Click emergency WAN restore

# Service & Watchdog
tachyon ai_heal                         # Trigger immediate self-healing cycle
tachyon ai_status                       # Concise Watchdog status JSON
tachyon ai_status_full                  # Full Watchdog telemetry JSON

# Component Management
tachyon check_update <component>        # Check for component updates
tachyon component_action install <comp> # Install or update component
```

### Local Test Execution
```sh
# Frontend vitest suite
npm --prefix fe-app-tachyon test

# Full backend suite in Docker CI
docker run --rm -v "$(pwd):/mnt" -w /mnt ucode-ci-img:latest bash tests/run_all.sh
```
