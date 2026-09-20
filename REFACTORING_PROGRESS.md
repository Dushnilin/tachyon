# TACHYON REFACTORING — TRACKING DOCUMENT

Каждый этап — отдельная ветка. Все тесты зелёные. После мержа — пометка DONE.

---

## ЛЕГЕНДА

- **DONE** — реализовано, тесты зелёные, замержено
- **IN PROGRESS** — ветка создана, реализация идёт
- **TODO** — ещё не начато
- **BLOCKED** — заблокировано依赖 от другого этапа

---

## BRANCH 1: refactor/process-identity

**Ветка:** `refactor/process-identity`
**Статус:** IN PROGRESS
**Зависит от:** —
**Файлы:** `core/process.uc` (новый), тест `tests/process_identity.sh`

### Что делаем:
- Единый модуль `core/process.uc` для process identity
- Функции: `verify()`, `is_alive()`, `start_ticks()`, `age_seconds()`, `matches()`
- Рефакторинг `service/state.uc`: `pid_alive()` → делегирование в process.uc
- Рефакторинг `service/state.uc`: `process_start_ticks()`, `process_age_seconds()` → делегирование
- Рефакторинг `core/exec.uc`: `process_starttime()` → делегирование в process.uc
- Тест `tests/process_identity.sh`: PID alive, dead PID, recycled PID, starttime match, boot_id match

### Готово:
- [x] core/process.uc создан (402 строки, 11 функций)
- [x] core/process.uc selftest (12 assertions)
- [x] Миграция state.uc: pid_alive → is_tachyon_process, process_start_ticks, process_age_seconds, pid_is_sing_box → is_sing_box
- [x] Миграция exec.uc: boot_id, process_starttime, make_identity, identity_matches, identity_alive, is_alive → делегируют в process.uc
- [x] Тест tests/process_identity.sh (275 строк, CLI + runtime тесты)
- [ ] Все существующие тесты зелёные (требуется ucode на Linux)
- [ ] Коммит + ветка готова к мержу

---

## BRANCH 2: refactor/structured-logging

**Ветка:** `refactor/structured-logging`
**Статус:** TODO
**Зависит от:** —
**Файлы:** `core/logging.uc` (новый)

### Что делаем:
- Единый модуль `core/logging.uc` с structured logging
- Поля: timestamp, level, subsystem, operation, job_id, correlation_id, message
- CLI: `core/logging.uc log info component.update "message"`
- Миграция 25 определений log_message() → require("core.logging")
- Тест: все модули используют единый logger

### Готово:
- [ ] core/logging.uc создан
- [ ] Миграция всех модулей
- [ ] Тест tests/logging_module.sh
- [ ] Все тесты зелёные

---

## BRANCH 3: refactor/packages-lock

**Ветка:** `refactor/packages-lock`
**Статус:** TODO
**Зависит от:** process-identity
**Файлы:** `core/packages.uc` (доработка)

### Что делаем:
- Stale lock detection с owner PID info
- Deadline с сообщением "FAILED: package database remained locked for 60s by PID 1843 (apk add ...)"
- Определение stale vs реальный владелец lock
- Тест: APK lock contention, stale lock, deadline

### Готово:
- [ ] Доработка packages.uc
- [ ] Тест tests/packages_lock_contention.sh
- [ ] Все тесты зелёные

---

## BRANCH 4: refactor/god-module-components

**Ветка:** `refactor/god-module-components`
**Статус:** TODO
**Зависит от:** process-identity, structured-logging
**Файлы:** components/ (разбивка action.uc)

### Что делаем:
- `components/action.uc` (4250 строк) → orchestration layer
- `components/catalog.uc` — поиск пакетов, версий
- `components/downloader.uc` — download с retry, mirror
- `components/verifier.uc` — SHA256, checksum
- `components/installer.uc` — APK/OPKG install
- `components/rollback.uc` — rollback logic
- `components/versions.uc` — version comparison
- Тест: компонентный update/install/remove

### Готово:
- [ ] components/catalog.uc
- [ ] components/downloader.uc
- [ ] components/verifier.uc
- [ ] components/installer.uc
- [ ] components/rollback.uc
- [ ] components/versions.uc
- [ ] action.uc → orchestration layer
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 5: refactor/god-module-diagnostics

**Ветка:** `refactor/god-module-diagnostics`
**Статус:** TODO
**Зависит от:** structured-logging
**Файлы:** diagnostics/ (разбивка runtime.uc)

### Что делаем:
- `diagnostics/runtime.uc` (5623 строки) →
  - `diagnostics/dns.uc` — DNS checks
  - `diagnostics/network.uc` — network checks
  - `diagnostics/routing.uc` — routing checks
  - `diagnostics/memory.uc` — memory checks
  - `diagnostics/components.uc` — component status
  - `diagnostics/repairs.uc` — auto-repair
  - `diagnostics/report.uc` — report generation
- Тест: каждый подмодуль

### Готово:
- [ ] diagnostics/dns.uc
- [ ] diagnostics/network.uc
- [ ] diagnostics/routing.uc
- [ ] diagnostics/memory.uc
- [ ] diagnostics/components.uc
- [ ] diagnostics/repairs.uc
- [ ] diagnostics/report.uc
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 6: refactor/god-module-fuzzer

**Ветка:** `refactor/god-module-fuzzer`
**Статус:** TODO
**Зависит от:** —
**Файлы:** diagnostics/fuzzer/ (разбивка)

### Что делаем:
- `diagnostics/fuzzer.uc` (4036 строк) →
  - `diagnostics/fuzzer/engine.uc`
  - `diagnostics/fuzzer/runner.uc`
  - `diagnostics/fuzzer/probes.uc`
  - `diagnostics/fuzzer/scoring.uc`
  - `diagnostics/fuzzer/sandbox.uc`
  - `diagnostics/fuzzer/strategies/zapret.uc`
  - `diagnostics/fuzzer/strategies/zapret2.uc`
  - `diagnostics/fuzzer/strategies/byedpi.uc`
  - `diagnostics/fuzzer/suites/youtube.uc`
  - `diagnostics/fuzzer/suites/discord.uc`
  - `diagnostics/fuzzer/suites/twitch.uc`
  - `diagnostics/fuzzer/suites/generic.uc`
- Тест

### Готово:
- [ ] Все подмодули
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 7: refactor/god-module-telegram

**Ветка:** `refactor/god-module-telegram`
**Статус:** TODO
**Зависит от:** —
**Файлы:** service/telegram/ (разбивка)

### Что делаем:
- `service/telegram.uc` (3749 строк) →
  - `service/telegram/transport.uc`
  - `service/telegram/commands.uc`
  - `service/telegram/callbacks.uc`
  - `service/telegram/rendering.uc`
  - `service/telegram/runtime.uc`
- Тест

### Готово:
- [ ] Все подмодули
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 8: feature/transaction-engine

**Ветка:** `feature/transaction-engine`
**Статус:** TODO
**Зависит от:** process-identity, jobs, structured-logging
**Файлы:** `core/transaction.uc` (новый)

### Что делаем:
- Единый transaction engine
- Lifecycle: PLAN → PREFLIGHT → SNAPSHOT → MUTATE → VALIDATE → ACTIVATE → VERIFY → COMMIT
- Rollback: FAIL → ROLLBACK → VERIFY_ROLLBACK → ROLLED_BACK
- Применение к: Tachyon update, component update, sing-box variant switch, config apply, snapshot restore
- Тест: transaction state machine, rollback

### Готово:
- [ ] core/transaction.uc
- [ ] Интеграция с component update
- [ ] Интеграция с Tachyon update
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 9: feature/preflight

**Ветка:** `feature/preflight`
**Статус:** TODO
**Зависит от:** transaction-engine
**Файлы:** расширение core/ или service/

### Что делаем:
- Free RAM check
- /tmp capacity check
- overlay/free flash check
- Package database availability check
- Architecture detection
- Disk budget calculation (download + temp + old + new + rollback + metadata + reserve)
- Тест: preflight на different disk states

### Готово:
- [ ] Preflight module
- [ ] Disk budget calculation
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 10: feature/event-journal

**Ветка:** `feature/event-journal`
**Статус:** TODO
**Зависит от:** —
**Файлы:** доработка `core/events.uc`

### Что делаем:
- Bounded ring journal `/var/run/tachyon/events.jsonl`
- Structured events: ts, event, severity, source, job_id, correlation_id, message, data
- Secret redaction (tokens, passwords, API keys, Telegram token, proxy credentials)
- Ограничение размера файла и количества записей
- Тест: secret redaction, bounded growth

### Готово:
- [ ] Bounded ring journal
- [ ] Secret redaction
- [ ] Тест tests/event_journal_redaction.sh
- [ ] Все тесты зелёные

---

## BRANCH 11: feature/reconciler

**Ветка:** `feature/reconciler`
**Статус:** TODO
**Зависит от:** event_controller, jobs
**Файлы:** `service/reconciler.uc` (новый)

### Что делаем:
- Desired/actual state comparison
- Minimal repair (repair DNS ≠ full restart)
- Интеграция с event_controller
- Тест: reconciler detects diff, applies minimal repair

### Готово:
- [ ] service/reconciler.uc
- [ ] Интеграция с event_controller
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 12: refactor/watchdog-escalation

**Ветка:** `refactor/watchdog-escalation`
**Статус:** TODO
**Зависит от:** reconciler
**Файлы:** `service/watchdog.uc` (доработка)

### Что делаем:
- Escalation ladder L0-L5
- Watchdog = observer, reconciler = repair
- L0: observe → L1: retry probe → L2: repair subsystem → L3: reload → L4: restart service → L5: emergency
- Тест: escalation по уровням

### Готово:
- [ ] Watchdog refactor
- [ ] Escalation ladder
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 13: feature/route-explain

**Ветка:** `feature/route-explain`
**Статус:** TODO
**Зависит от:** —
**Файлы:** `singbox/route_explain.uc` или `routing/explain.uc`

### Что делаем:
- API `route_explain`: client → device section → domain/IP rule → DNS decision → routing rule → nft mark → routing table → outbound group → selected outbound
- Объяснение: why selected, why direct didn't match, why another rule didn't match
- Frontend human-readable
- Тест: route explain на various inputs

### Готово:
- [ ] route_explain API
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 14: feature/config-plan

**Ветка:** `feature/config-plan`
**Статус:** TODO
**Зависит от:** —
**Файлы:** API endpoint

### Что делаем:
- `config_plan` API: candidate state без активации
- Валидация: sing-box config, nft rules, DNS, outbounds, routes, required binaries, ports
- Возврат: `{ valid, changes, warnings, errors }`
- Frontend: "Preview Changes" button
- Тест

### Готово:
- [ ] config_plan API
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 15: feature/known-good

**Ветка:** `feature/known-good`
**Статус:** TODO
**Зависит от:** reconciler
**Файлы:** service/ или core/

### Что делаем:
- Last Known Good state concept
- Observation window (service stable + DNS works + routing works + no restart loop)
- Known-good state хранится в `/etc/tachyon/state/`
- Rollback prefers last known-good
- Тест

### Готово:
- [ ] Known-good module
- [ ] Observation window
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 16: feature/support-bundle

**Ветка:** `feature/support-bundle`
**Статус:** TODO
**Зависит от:** logging, event_journal
**Файлы:** CLI command

### Что делаем:
- `tachyon support_bundle` команда
- Архив: versions, build SHA, OpenWrt version, arch, free RAM, disk, service state, jobs, events, sanitized UCI, generated config, recent logs, nft rules, ip rules, DNS state, process list, FD counts
- Secret redaction: tokens, passwords, UUID, private keys, API keys, Telegram token, proxy credentials, subscription URLs
- Тест: secret redaction

### Готово:
- [ ] support_bundle команда
- [ ] Secret redaction
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 17: feature/release-signature

**Ветка:** `feature/release-signature`
**Статус:** TODO
**Зависит от:** —
**Файлы:** build.sh, install.sh, installer

### Что делаем:
- Minisig подпись manifest (sha256sums.txt.minisig)
- Public key в installer/package
- Download pipeline: download manifest → verify signature → download artifact → verify SHA256 → verify metadata → install
- Signature failure = hard failure
- Тест

### Готово:
- [ ] Minisig signature в build.sh
- [ ] Signature verification в install.sh
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 18: feature/command-cancellation

**Ветка:** `feature/command-cancellation`
**Статус:** TODO
**Зависит от:** jobs
**Файлы:** core/jobs.uc (доработка)

### Что делаем:
- `cancel_requested=true` в job state
- Worker проверяет cancel между фазами
- Critical section protection: finish current safe point → rollback if necessary → then cancel
- Тест: cancellation between phases, during critical section

### Готово:
- [ ] Cancel в jobs.uc
- [ ] Cooperative cancellation в worker
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 19: frontend/job-clients

**Ветка:** `frontend/job-clients`
**Статус:** TODO
**Зависит от:** backend job API
**Файлы:** fe-app-tachyon/src/tachyon/services/

### Что делаем:
- `services/jobClient.ts` — typed client для job state queries
- `services/eventClient.ts` — typed client для events
- `services/runtimeClient.ts` — typed client для runtime state
- Тест

### Готово:
- [ ] jobClient.ts
- [ ] eventClient.ts
- [ ] runtimeClient.ts
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 20: frontend/contract

**Ветка:** `frontend/contract`
**Статус:** TODO
**Зависит от:** —
**Файлы:** contracts/tachyon-rpc.json, build scripts

### Что делаем:
- `contracts/tachyon-rpc.json` — machine-readable RPC contract
- Build-time генерация: method names, TS request/response interfaces, validators
- Тест: contract compatibility

### Готово:
- [ ] tachyon-rpc.json
- [ ] Build-time генерация
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 21: frontend/controller-split

**Ветка:** `frontend/controller-split`
**Статус:** TODO
**Зависит от:** frontend/job-clients
**Файлы:** tabs/dashboard/, tabs/updates/, tabs/diagnostic/, tabs/monitoring/

### Что делаем:
- Dashboard: controller.ts, polling.ts, actions.ts, connections.ts, metrics.ts, render.ts
- Updates: controller.ts, jobs.ts, rendering.ts, notifications.ts
- Diagnostic: controller.ts + checks/*.ts + partials/*.ts
- Monitoring: controller.ts, ...
- Тест

### Готово:
- [ ] Dashboard split
- [ ] Updates split
- [ ] Diagnostic split
- [ ] Monitoring split
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 22: frontend/shell-surface

**Ветка:** `frontend/shell-surface`
**Статус:** TODO
**Зависит от:** frontend/contract, frontend/job-clients
**Файлы:** methods/shell/index.ts → замена на typed RPC

### Что делаем:
- Замена methods/shell/index.ts (1800 строк) на typed RPC calls
- RPC ACL: конкретные операции, не arbitrary root shell
- Shell compatibility layer на период миграции
- Тест

### Готово:
- [ ] Typed RPC methods
- [ ] ACL
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 23: frontend/proxy-validators

**Ветка:** `frontend/proxy-validators`
**Статус:** TODO
**Зависит от:** —
**Файлы:** validators/

### Что делаем:
- Fix TODO в validateProxyUrl.ts и validateShadowsocksUrl.ts
- Table-driven tests: IPv4, IPv6, hostname, invalid port, missing port, base64, URL-safe base64, percent encoding, unicode, very long input, invalid credentials, fragment/name, duplicate query args, unknown protocol, malformed URI
- Все external subscription inputs = untrusted
- Тест

### Готово:
- [ ] validateProxyUrl.ts fix
- [ ] validateShadowsocksUrl.ts fix
- [ ] Table-driven tests
- [ ] Все тесты зелёные

---

## BRANCH 24: frontend/stability-dashboard

**Ветка:** `frontend/stability-dashboard`
**Статус:** TODO
**Зависит от:** event_journal, logging
**Файлы:** tabs/stability/ или расширение dashboard

### Что делаем:
- Aggregated diagnostics: Tachyon uptime, sing-box uptime, watchdog restart count, DNS failovers, WAN recoveries, component failures, rollback count, jobs failed, memory pressure events, current FD count, orphan process count
- Компактная история
- Тест

### Готово:
- [ ] Stability dashboard
- [ ] Тесты
- [ ] Все тесты зелёные

---

## BRANCH 25: ci/guards

**Ветка:** `ci/guards`
**Статус:** TODO
**Зависит от:** —
**Файлы:** .github/workflows/

### Что делаем:
- CI workflow: backend tests, frontend tests, shellcheck
- Static guards: запрет на новые raw system(), fs.popen(), sh -c, background &, direct uci commit
- Baseline allowlist (существующие legacy occurrences)
- Тест: guard блокирует новые violations

### Готово:
- [ ] .github/workflows/backend-ci.yml
- [ ] .github/workflows/frontend-ci.yml
- [ ] Static guard script
- [ ] Baseline allowlist
- [ ] Все тесты зелёные

---

## BRANCH 26: ci/fault-injection

**Ветка:** `ci/fault-injection`
**Статус:** TODO
**Зависит от:** —
**Файлы:** tests/fault_*.sh

### Что делаем:
- Fault injection тесты:
  - kill worker, kill parent
  - WAN disappears, DNS unavailable
  - full /tmp, full overlay
  - APK lock, OPKG lock
  - corrupted package, wrong checksum, wrong signature
  - invalid generated config
  - sing-box fails after activation
  - rpcd restart during operation
  - PID reuse, stale job, stale lock
  - reboot simulation
- После fault: job terminal state, lock cleanup, process cleanup, rollback, error message
- Тест

### Готово:
- [ ] Все fault injection тесты
- [ ] Все тесты зелёные

---

## BRANCH 27: ci/soak-test

**Ветка:** `ci/soak-test`
**Статус:** TODO
**Зависит от:** —
**Файлы:** tests/soak_*.sh

### Что делаем:
- Nightly stability test:
  - 100 start/stop
  - 100 reload
  - 100 config regenerations
  - 50 service actions
  - 50 DNS failure/recovery
  - 20 simulated component updates
  - 20 subscription updates
- Baseline/final: RSS, FD count, process count, logread count, worker count, locks, /tmp files, zombies
- Acceptance: orphan workers=0, stale locks=0, zombies=0, no unbounded FD/RSS growth
- Тест

### Готово:
- [ ] Soak test script
- [ ] Acceptance criteria
- [ ] Все тесты зелёные

---

## BRANCH 28: docs/architecture

**Ветка:** `docs/architecture`
**Статус:** TODO
**Зависит от:** все предыдущие
**Файлы:** docs/knowledge-base/

### Что делаем:
- JOB_ENGINE.md
- TRANSACTION_ENGINE.md
- STATE_MODEL.md
- RECONCILER.md
- EVENTS.md
- Обновление основного architecture document
- Документация = фактический код

### Готово:
- [ ] JOB_ENGINE.md
- [ ] TRANSACTION_ENGINE.md
- [ ] STATE_MODEL.md
- [ ] RECONCILER.md
- [ ] EVENTS.md
- [ ] Основной architecture document обновлён
