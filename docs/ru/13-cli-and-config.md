# Справочник CLI и конфигурации

[English](../en/13-cli-and-config.md) | [К оглавлению](README.md)

## Командная строка `/usr/bin/tachyon`

Если фоновый демон `tachyon daemon` уже запущен, большинство диагностических подкоманд автоматически проксируются к нему через локальный UBUS/HTTP-интерфейс для получения живого состояния памяти и активных сессий.

### Все поддерживаемые подкоманды CLI (`src/main.rs`)

| Команда | Аргументы | Описание |
|---|---|---|
| `tachyon version` (`-v`, `--version`) | — | Выводит текущую версию `tachyon` |
| `tachyon status` | — | Запускает локальный `Doctor` и выводит JSON-отчёт о состоянии системы и ядра |
| `tachyon explain` | `<target> [client_ip]` | Объясняет маршрут до цели через живое ядро (`www.youtube.com` / `192.168.1.100` по умолчанию) |
| `tachyon route_explain` | `[client_ip] [target] [port] [protocol]` | Симуляция прохождения правил по секциям и условиям (по умолчанию `192.168.1.100 www.youtube.com 443 tcp`) |
| `tachyon config_plan` | — | Проверяет текущую конфигурацию на коллизии правил и выводит план валидации в JSON |
| `tachyon compile_config` | — | Выводит скомпилированный JSON-конфиг `tachyon-core` без перезапуска службы |
| `tachyon compile_nft` | — | Печатает сгенерированный набор правил `nftables` в stdout |
| `tachyon quick_fix` | `[fix_id]` | Применяет безопасное исправление по идентификатору (по умолчанию `restart_core`) |
| `tachyon rollback` | — | Откатывает конфигурацию к последнему известному рабочему состоянию (`rollback_known_good`) |
| `tachyon import-legacy` (`import_legacy`) | `[uci_path] [sub_cache_dir]` | Импортирует устаревший UCI-конфиг `/etc/config/tachyon` в `/etc/tachyon/tachyon.json` |
| `tachyon support_bundle` | — | Собирает обезличенный отладочный пакет `support_bundle` в JSON |
| `tachyon mcp` | — | Запускает MCP-сервер в режиме JSON-RPC 2.0 поверх `stdio` (для локальных ИИ-агентов) |
| `tachyon start` / `stop` | — | Запускает или останавливает процесс `tachyon-core` |
| `tachyon reload` / `restart` | — | Пересобирает конфиг и применяет изменения на работающем ядре |
| `tachyon daemon` (`serve`, `--daemon`) | — | Основной режим работы фонового демона оркестратора (по умолчанию без аргументов) |

Также поддерживаются пробросы сервисных команд через `/etc/init.d/tachyon` и внутренние RPC-методы LuCI (списки, проверки, обновления компонентов), обрабатываемые модулем `ubus_bridge`.

## Структура конфигурационных файлов

### Постоянное хранилище (`/etc/tachyon/`, Flash)

- **`/etc/tachyon/tachyon.json`** — основная база данных конфигурации в формате JSON (`RouterStoreData`, `src/store.rs`). Корневые ключи:

| Ключ | Назначение |
|---|---|
| `settings` | Глобальные параметры (`GlobalSettings`: режим перехвата, DNS/FakeIP, IPv6/WebRTC, каналы обновлений, SQM/TCP, Tailscale, ИИ-диагностика, Web UI, защита флеш) |
| `sections` | Список секций маршрутизации (`RoutingSection`: порядок, `action`, ссылки на `condition_refs`, `outbound_source_refs`, `balancer_refs`, `fail_closed`, `kill_switch`) |
| `conditions` | Атомарные и составные булевы условия отбора трафика (`TrafficCondition`) |
| `outbound_sources` | Глобальный пул подключений первого уровня (`OutboundSource`: подписки, share-ссылки, AWG, WARP, FPTN, OpenVPN, Desync и др.) |
| `balancers` | Политики балансировки и резервирования (`BalancerConfig`: `balancer_type`, `mode`, URL проверок, интервалы, уровни) |
| `outbound_groups` | Переиспользуемые группы узлов для многоуровневых балансировщиков (`OutboundGroup`) |
| `servers` | Конфигурация входящих VPN/прокси-серверов на роутере (`InboundServer`) |
| `profiles` | Семейные профили устройств и фильтрации (`ParentalProfile`) |
| `schedules` | Правила расписаний блокировок и ограничений (`ScheduleRule`) |
| `guest_mode` | Конфигурация гостевого сегмента и квот (`GuestModeConfig`) |
| `telegram` | Параметры Telegram-бота, уведомлений и списка роутеров парка (`TgBotConfig`) |
| `device_registry` | Метаданные и привязки известных устройств локальной сети (`DeviceMeta`) |
| `applied_migrations` | Журнал выполненных версионных миграций конфигурации |

- **`/etc/tachyon/config_sections.json`** — синхронизированное представление секций в формате LuCI UCI.
- **`/etc/tachyon-core/config.json`** — автоматически компилируемый конфиг для `/usr/bin/tachyon-core` (не редактируйте вручную — перезаписывается при каждом `reload`).
- **`/etc/tachyon/rulesets/`**, **`/etc/tachyon/subscription-cache/`**, **`/etc/tachyon/hosts-lists/`** — кэшированные списки `.trs`, подписки и hosts-файлы (обновляются с проверкой неизменности содержимого).

### Оперативное состояние (`/var/run/tachyon/` и `/tmp/`, RAM / tmpfs)

Следующие пути находятся строго в оперативной памяти и не расходуют ресурс флеш-памяти:

- `/var/run/tachyon/section-errors.json` — секции в карантине с описанием ошибки валидации.
- `/var/run/tachyon/system-info.json` и `/var/run/tachyon/ui-state/` — кэш телеметрии и состояния прокси/соединений для UI.
- `/var/run/tachyon/section-cache/` — распарсенные метаданные узлов, балансировщиков и подписок по секциям.
- `/var/run/tachyon/telegram.heartbeat` — метка активности цикла опроса Telegram-бота.
- `/tmp/tachyon-core/tachyon-core.log` — журнал работы `tachyon-core`.
- `/tmp/tachyon-install.log` — журнал последнего запуска установщика.

> [!TIP]
> На нестандартных или тестовых окружениях путь каталога данных можно переопределить переменной окружения `TACHYON_DATA_DIR`.

---

[Предыдущая: Устранение неполадок и FAQ](12-troubleshooting-faq.md) | [К оглавлению](README.md) | [Следующая: Agent REST API и MCP-сервер](14-api-and-mcp.md)
