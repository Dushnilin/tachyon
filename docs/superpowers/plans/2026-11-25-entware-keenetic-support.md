# План реализации: Универсальный слой Entware + Keenetic / Netcraze + USB (`tachyon` 2.0)

> Ссылка на спецификацию: [2026-11-25-entware-keenetic-support-design.md](2026-11-25-entware-keenetic-support-design.md)

## Волна 0 — Подготовка (Координатор)
- Локальная интеграция PR #498, #497, #496 в ветку `2.0`.
- Фиксация спецификации и плана, инициализация роя и `plan.json`.

## Волна 1 — Платформенный фундамент (`platform-core`)
- `src/platform.rs`: определение ОС/фаервола/хранилища USB, RAM `tmpfs` (по `/proc/mounts`), релоцируемые пути `PlatformPaths`, `has_managed_dnsmasq()`, `write_file_if_changed_durable()`.
- `src/platform_keenetic.rs`: локальный RCI-клиент (`127.0.0.1:79/rci/`).
- `src/store.rs`: настройки `entware_dns_mode`, `entware_dns_port`, привязка путей к `platform::paths()`.
- `src/main.rs`: подключение модулей, CLI `reconcile-net` и `compile_iptables`.

## Волна 2 — Параллельная реализация компонентов
- **`net-iptables`**: `src/net_stack_iptables.rs`, интеграция в `src/net_stack.rs` и `src/config_gen.rs` (в т.ч. Split-DNS guard для PR #496 и Entware DNS `:1053`).
- **`runtime-sys`**: перевод путей и платформенная адаптация `src/core_mgr.rs`, `src/sys_info.rs`, `src/diagnostics.rs`, `src/watchdog.rs`, `src/updater.rs`, `src/ai_doctor.rs`.
- **`api-bridge-exit`**: `src/api.rs` и `src/ubus_bridge.rs` — релоцируемая статика/пути, `platform_info`, endpoint `GET /api/exit-country` и RPC `get_exit_country` (#499).
- **`entware-packaging`**: `entware/S99tachyon`, хуки NDM/Merlin, `tools/build_entware_pkg.py`, `tools/test_entware_pkg.py`, обновление `build.sh`, `install.sh`, `uninstall.sh`, `.github/workflows/build.yml`, `.github/workflows/ci.yml`.
- **`frontend-ux`**: пометка `(Рекомендуется)` для `russia_inside` (#494), виджет фактической страны выхода (#499), отображение среды Entware/USB и настроек Entware DNS, `npm run locales:actualize && npm run ci`.

## Волна 3 — Интеграция, проверка CI и локальные коммиты
- Аудит Linux 4.9 / MIPS32 (`AtomicU64`) / Pure-Rust `cargo tree`.
- Полный прогон `cargo fmt`, `cargo clippy -- -D warnings`, `RUST_MIN_STACK=524288 cargo test --all-targets --locked`, `npm run ci`, `shellcheck --severity=error`, `py_compile` + `test_entware_pkg.py`.
- Локальные коммиты в `G:\tachyon-rs` (`2.0`) без пуша.
