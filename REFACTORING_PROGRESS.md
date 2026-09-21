# TACHYON REFACTORING — TRACKING DOCUMENT

Каждый этап — отдельная ветка. Все тесты зелёные. После мержа — пометка DONE.

---

## ЛЕГЕНДА

- **DONE** — реализовано, тесты зелёные, замержено
- **IN PROGRESS** — ветка создана, реализация идёт
- **TODO** — ещё не начато

---

## BRANCH 1: refactor/process-identity

**Ветка:** `refactor/process-identity`
**Статус:** DONE (pushed, awaiting merge)
**Зависит от:** —
**Файлы:** `core/process.uc` (новый), `core/exec.uc` (обновлён), `service/state.uc` (обновлён), `tests/process_identity.sh`

### Готово:
- [x] core/process.uc создан (402 строки, 11 функций)
- [x] core/process.uc selftest (12 assertions)
- [x] Миграция state.uc: pid_alive → is_tachyon_process, process_start_ticks, process_age_seconds, pid_is_sing_box → is_sing_box
- [x] Миграция exec.uc: boot_id, process_starttime, make_identity, identity_matches, identity_alive, is_alive → делегируют в process.uc
- [x] Тест tests/process_identity.sh (275 строк, CLI + runtime тесты)
- [x] Frontend tests: 635 passed (pre-push hook)
- [x] Коммит + push

---

## BRANCH 2: refactor/structured-logging

**Ветка:** `refactor/structured-logging`
**Статус:** IN PROGRESS
**Зависит от:** —
**Файлы:** `core/logging.uc` (новый), `core/common.uc` (обновлён), `tests/logging_module.sh`

### Готово:
- [x] core/logging.uc создан (250 строк)
- [x] core/logging.uc selftest (6 assertions)
- [x] core/common.uc делегирует log_message → logging.uc
- [x] Тест tests/logging_module.sh
- [ ] Миграция остальных модулей (post-merge, постепенно)
- [ ] Все тесты зелёные (требуется ucode на Linux)
- [ ] Коммит + ветка готова к мержу

---

## BRANCH 3: refactor/packages-lock — TODO
## BRANCH 4: refactor/god-module-components — TODO
## BRANCH 5: refactor/god-module-diagnostics — TODO
## BRANCH 6: refactor/god-module-fuzzer — TODO
## BRANCH 7: refactor/god-module-telegram — TODO
## BRANCH 8: feature/transaction-engine — TODO
## BRANCH 9: feature/preflight — TODO
## BRANCH 10: feature/event-journal — TODO
## BRANCH 11: feature/reconciler — TODO
## BRANCH 12: refactor/watchdog-escalation — TODO
## BRANCH 13: feature/route-explain — TODO
## BRANCH 14: feature/config-plan — TODO
## BRANCH 15: feature/known-good — TODO
## BRANCH 16: feature/support-bundle — TODO
## BRANCH 17: feature/release-signature — TODO
## BRANCH 18: feature/command-cancellation — TODO
## BRANCH 19: frontend/job-clients — TODO
## BRANCH 20: frontend/contract — TODO
## BRANCH 21: frontend/controller-split — TODO
## BRANCH 22: frontend/shell-surface — TODO
## BRANCH 23: frontend/proxy-validators — TODO
## BRANCH 24: frontend/stability-dashboard — TODO
## BRANCH 25: ci/guards — TODO
## BRANCH 26: ci/fault-injection — TODO
## BRANCH 27: ci/soak-test — TODO
## BRANCH 28: docs/architecture — TODO
