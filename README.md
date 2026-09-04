<div align="center">

![Tachyon Banner](assets/readme/hero.svg)

[![Stars](https://img.shields.io/github/stars/Dushnilin/tachyon?style=for-the-badge&color=00F0FF)](https://github.com/Dushnilin/tachyon/stargazers)
[![Releases](https://img.shields.io/github/v/release/Dushnilin/tachyon?style=for-the-badge&color=818CF8)](https://github.com/Dushnilin/tachyon/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20SNAPSHOT-10B981?style=for-the-badge&logo=openwrt)](https://openwrt.org/)
[![Telegram](https://img.shields.io/badge/Telegram-Канал-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/tachyon_proxy)
[![License](https://img.shields.io/github/license/Dushnilin/tachyon?style=for-the-badge&color=C084FC)](LICENSE)

[**🇷🇺 Русский**](README.md) | [**🇬🇧 English**](README.en.md)

</div>

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## ⚡ О проекте

**Tachyon** — это высокопроизводительное, автономное и бескомпромиссное решение для оркестрации сетевого трафика, проксирования и обхода цензуры на роутерах под управлением **OpenWrt** (полная совместимость с **OpenWrt 23.05, 24.10, 25.x и SNAPSHOT**). Прямой форк проекта **[Forkop от @ushan0v](https://github.com/ushan0v/forkop)** (ранее **Podkop Plus**).

Tachyon объединяет ядро **sing-box**, средства локального аппаратного обхода DPI (**Zapret v1 / Zapret v2 / ByeDPI**), интерактивный комбинаторный **DPI Strategy Fuzzer**, защищённый **Telegram-бот управления**, а также инновационный **AI Stack** (автономный **AI Doctor v2.5**, офлайн-диагностику, **HTTP REST Agent API / OpenAPI 3.0** и **MCP Server** для подключения ИИ-агентов).

Вся внутренняя логика реализована на скриптовом движке **ucode** — нативном C-интерпретаторе OpenWrt, обеспечивающем ультранизкое потребление RAM (от 128 МБ ОЗУ) и мгновенный отклик.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🌐 Архитектура и конвейер трафика

<div align="center">

![Tachyon Traffic Pipeline](assets/readme/architecture.svg)

</div>

Tachyon перехватывает сетевой стек через ядро **nftables** и распределяет запросы без лишних задержек:
1. **Прямой трафик (Direct WAN)**: Отечественные сервисы, банки, Госуслуги и доверенные ресурсы идут без прокси с нулевой задержкой (`0 ms overhead`).
2. **Zapret v1 (`nfqws`)**: Базовая десинхронизация TCP/UDP (`fake`, `disorder`, `split2`) прямо на роутере без VPS.
3. **Zapret v2 (`nfqws2`)**: Адаптивный многовекторный обход ТСПУ (`multisplit`, `seqovl`, `wsize`, PAWS `tcp_ts`, аутентичные `blobs`) для YouTube 4K, Discord и стриминга.
4. **ByeDPI (`ciadpi`)**: Локальный SOCKS5-десинхронизатор с фрагментацией полезной нагрузки HTTP/TLS SNI.
5. **Зашифрованный прокси-туннель (sing-box)**: Заблокированные ресурсы и приватный трафик направляются через защищённые протоколы (VLESS Reality, Hysteria2, WireGuard, AmneziaWG).
6. **Smart DNS Pipeline**: Изолированная обработка DNS через FakeIP (`198.18.0.0/15`), DoH/DoT/DoQ с защитой от перехвата провайдером и автоматическим отказоустойчивым переключением (DNS Failover).

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🔥 Главные возможности и подсистемы

### 🛡️ 1. Мультипротокольное проксирование и умный DNS-стек
* **Ядро sing-box Engine (v1.11+)**: Нативная поддержка современных защищённых протоколов — **VLESS (Reality / gRPC / WS)**, **VMess**, **Shadowsocks**, **Trojan**, **Hysteria2**, **WireGuard / AmneziaWG**.
* **Генератор профилей Cloudflare WARP / AmneziaWG (`generate_warp`)**: Быстрое создание готовых конфигураций WireGuard и AmneziaWG прямо на роутере без сторонних скриптов.
* **Многомерная селективная маршрутизация**: 
  * **По доменам и IP-сетям**: Направляйте через прокси или десинк только целевой трафик.
  * **По клиентским устройствам (MAC / IP)**: Индивидуальные правила для Smart TV, смартфонов, ПК и консолей.
  * **По GeoIP и странам**: Гибкие списки включения/исключения по странам назначения.
* **Автоматические подписки**: Фоновая загрузка, распарсинг и обновление прокси-нод по подписочным URL с авто-тестированием RTT задержки и группами серверов (URL-Test, Failover).
* **🌐 Умный сетевой стек DNS и Failover**:
  * **FakeIP-пул (`198.18.0.0/15`)**: Мгновенное установление соединений без предварительного ожидания ответа удалённого DNS.
  * **Поддержка современных протоколов DNS**: DoH (DNS over HTTPS), DoT (DNS over TLS), DoQ (DNS over QUIC) и DNS over HTTP/3.
  * **Автономный DNS Failover демон (`dns_failover.uc`)**: Непрерывный мониторинг апстримов и мгновенное бесшовное переключение на резервные резолверы при сбоях.
  * **Анти-перехват DNS**: Прозрачный перехват портов 53 UDP/TCP в ядре nftables, исключающий перехват запросов провайдерами.
  * **Интерактивный DNS Benchmark (`tachyon dns_benchmark`)**: Тестирование скорости и доступности популярных DNS-серверов с функцией автотюнинга (`dns_autotune`).
* **🌐 Секции Hosts и Списки DNS-блокировок (Hosts Engine)**:
  * **Статический DNS-Overriding (`dns_hosts`)**: Прямое переопределение IP для доменов в DNS-модуле sing-box и dnsmasq без правки `/etc/hosts`.
  * **Загрузка сторонних списков Hosts (`hosts_list_urls`)**: Авто-загрузка и парсинг реестров блокировок (AdAway, StevenBlack, списки Антизапрет).
  * **Умный кэш (`combined.txt`)**: Дедупликация, слияние и кэширование внешних источников списков.
  * **Резервирование через зеркала (GitHub Mirror Retry)**: Автопереключение на зеркала (`cdn.jsdelivr.net`, `gh-proxy.com`, `ghproxy.net`) при блокировках GitHub.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🚀 2. God-Tier Генератор и Фаззер стратегий обхода ТСПУ (DPI Fuzzer Engine)
* **Автономный комбинаторный фаззинг**: Встроенный интеллектуальный фаззер прямо в веб-интерфейсе LuCI и CLI (`tachyon fuzzer_start`), тестирующий и подбирающий оптимальные параметры десинхронизации для **Zapret2 (`nfqws2`)**, **Zapret v1 (`nfqws`)** и **ByeDPI (`ciadpi`)**.
* **PAWS TCP Timestamp Spoofing (`tcp_ts=-600000:tcp_ts_up`)**:
  Инновационная техника десинхронизации ТСПУ через устаревшие временные метки TCP. Фейковые ClientHello отправляются с timestamp, сдвинутым на 10 минут назад: конечный сервер отбрасывает их согласно RFC 7323 PAWS, а ТСПУ десинхронизируется и пропускает целевой трафик.
* **Аутентичные бинарные дампы (Blobs)**:
  Встроенная поддержка дампов ClientHello, QUIC и STUN (`tls_max`, `tls_google`, `tls_gosuslugi`, `tls_sber`, `tls_iana`, `tls_vk`, `quic_google`, `stun_fake`, `discord_udp`). Фаззер автоматически находит нужные блобы на роутере и пробрасывает параметры в демон.
* **Точное перекрытие последовательностей (SeqOvl Pattern Overlap)**:
  Стратегии с байтовым перекрытием (`seqovl=664:seqovl_pattern=tls_max`, `seqovl=681:seqovl_pattern=tls_google`), склеивающие доверенный SNI поверх блокируемого в reassembly-буфере ТСПУ.
* **TCP SYN Data (`--lua-desync=syndata`) и сжатые Lua-скрипты**:
  Инъекция полезной нагрузки в TCP SYN-пакет в связке с `multidisorder` и `multisplit`, а также автозагрузка сценариев `.lua.gz`.
* **Огромная база валидированных стратегий**:
  * **286+ комбинаторных стратегий Zapret2** (включая YouTube 4K Kyber, GoogleVideo CDN стримы, Discord Voice + RTC UDP, Fakedsplit, Fakeddisorder, Hostfakesplit и матрицу Low-TTL 3–8 с методами `badseq`, `md5sig`, `badack`, `datanoack`).
  * 130 стратегий для Zapret v1 и 65 для ByeDPI.
* **Таргет-сьюты сервисов**: Готовые профили проверок для `youtube_suite`, `discord_suite`, `twitch_suite` (HLS Usher), `twitter_suite`, `chatgpt_suite`.
* **Изолированная очередь в nftables (`0x00200000`)**: Фаззер тестирует стратегии через прямую выделенную очередь Netfilter без влияния на обычный трафик домашней сети и TProxy.
* **Применение в 1 клик (`🏆 Best Match`)**: Возможность сразу применить найденную лучшую стратегию в конфигурацию UCI роутера.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🤖 3. ИИ-Доктор, REST Agent API и MCP Server (AI Stack v2.5)

<div align="center">

![AI Doctor Monitor](assets/readme/ai_doctor_showcase.svg)

</div>

* **Tachyon AI Doctor (v2.5)**: Глубокая диагностика роутера с использованием LLM (**OpenAI**, **Anthropic Claude**, **DeepSeek** или локальных моделей через OpenRouter / Ollama).
  * **Глубокий контекст**: Передаёт в модель не только текущие проверки, но и метрики Watchdog (OOM, серии сбоев) и последние сжатые логи роутера.
  * **Многокомпонентные цепочки фиксов (Multi-Fix)**: Возвращает цепочку автоматических исправлений с кнопками для каждого фикса и кнопкой «Исправить всё».
* **🩺 Офлайн-диагностика Local Rule Doctor**:
  * **13 встроенных Quick Fix кодов**: Авто-ремонт sing-box, nftables, dnsmasq, resolv.conf, очистка кэша DNS, обновление подписок и перезапуск сетевого стека.
  * **Синхронизация времени NTP (`fix_system_time`)**: Автоматическое обнаружение и исправление сбоя системных часов.
  * **Сброс conntrack (`flush_conntrack`)**: Ликвидация переполнения таблицы трансляции соединений при сетевых штормах.
  * **DNS Dead-lock Repair (`fix_bootstrap_dns`)**: Предотвращение циклических блокировок первичных DNS sing-box.
  * **Оптимизация MTU туннелей (`optimize_mtu`)**: Расчёт оптимального размера пакета для AWG/WireGuard.
* **🚨 Аварийное восстановление интернета (Native Internet Fallback)**:
  * Мгновенный возврат чистого интернета одной кнопкой в UI или командой `tachyon restore_native_internet`. Полная чистая остановка прокси и сброс правил nftables/ip rule без перезагрузки роутера.
* **🔌 Model Context Protocol (MCP) Server**:
  * Встроенная поддержка стандарта MCP (`tachyon mcp`) через JSON-RPC 2.0 stdio: прямое подключение роутера к Claude Desktop, Cursor, Antigravity и внешним ИИ-агентам в качестве сетевого инструмента.
* **🌐 HTTP REST Agent API (OpenAPI 3.0)**:
  * Полноценный программный REST API (`/cgi-bin/tachyon-agent/`) для мониторинга, управления правилами и автоматизации.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 📱 4. Интерактивный Telegram-бот управления

<div align="center">

![Telegram Bot Showcase](assets/readme/telegram_bot_showcase.svg)

</div>

Полноценный, отказоустойчивый пульт управления роутером прямо из мессенджера:
* **Управление правилами «на лету»**: Просмотр списков обхода и моментальное добавление новых доменов или IP-сетей.
* **Интерактивный редактор секций**: Включение, выключение и детальная настройка правил маршрутизации.
* **Переключение серверов**: Выбор активных прокси-нод с автоматическим замером задержки (RTT ping) и защитой от переполнения кнопок (токены `cb_data`).
* **Мониторинг соединений в реальном времени (`/connections`)**: Просмотр активных клиентских сессий с пагинацией и кнопкой экстренного закрытия всех соединений (`/close_connections`).
* **Тихие часы (`/qh`)**: Настройка периодов тишины без ночных оповещений.
* **Управление устройствами LAN**: Просмотр активных клиентов и блокировка/разблокировка доступа по MAC-адресам.
* **Отказоустойчивый транспорт**: Автоматический фоллбек на прямой WAN при сбоях прокси, раздельные таймауты `curl` (12с для команд / 35с для long-polling) и защита от сбоев парсинга HTML-разметки.
* **Диагностика и Команды**: `/doctor`, `/ai_doctor`, `/heal`, `/speed`, `/ping`, `/test`, `/logs`, `/info`, `/export_config`, `/restart`, `/lang`.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🛡️ 5. Watchdog — Защита, Самовосстановление и Снапшоты

<div align="center">

![Watchdog Showcase](assets/readme/watchdog_showcase.svg)

</div>

Watchdog — сердце стабильности Tachyon, работающее каждые 5–15 секунд без внешних зависимостей:
* **Атомарные записи и UCI-бэкапы**: Запись конфигураций через паттерн `tmp` + `mv` предотвращает повреждение файлов при внезапном выключении питания роутера.
* **Защита от зацикливания перезапусков (Restart-Loop Prevention)**: Лимит не более 3 перезапусков за 10 минут (`safe_proxy_restart()`), мьютекс `PROXY_RESTART_LOCK` и кулдаун DNS-петель.
* **Оптимизация памяти (OOM Watchdog)**: Динамическая регулировка `GOMEMLIMIT` при нехватке ОЗУ с отправкой предупреждений в Telegram.
* **Мягкая перезагрузка (Hot-Reload)**: Смена серверов и правил без разрыва активных TCP-соединений (Discord, онлайн-игры и стримы не прерываются).
* **Снапшоты конфигурации (Snapshots & Rollback)**: Мгновенное создание снимков состояния (`snapshot_save <name>`), их просмотр и откат в случае ошибок (`snapshot_restore <file>`).
* **Восстановление WAN и шлюзов**: Мониторинг сетевых интерфейсов и авто-поднятие при сбоях провайдера.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 👶 6. Родительский контроль, квоты и Smart QoS
* **Поустройственные ограничения**: Установка расписания интернет-доступа (по часам и дням недели) индивидуально для каждого смартфона, планшета или ТВ.
* **Квотирование трафика**: Задание лимитов входящего и исходящего трафика на клиентские устройства с автоматическим сбросом по cron (`parental_quota.uc`).
* **Smart QoS & Priority Daemon**:
  * Маркировка пакетов DSCP в ядре nftables для приоритизации критичного трафика (голос, Discord, Zoom, онлайн-игры).
  * Предотвращение задержек и раздувания очередей (Bufferbloat) при максимальной загрузке интернет-канала торрентами или обновлениями.
* **Мгновенная изоляция**: Блокировка и разблокировка доступа в интернет для любого устройства в один клик из LuCI или Telegram.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🖥️ 7. Современный Web-интерфейс LuCI (TypeScript)

<div align="center">

![LuCI Web UI Showcase](assets/readme/luci_web_showcase.svg)

</div>

* Полная интеграция в штатный Web-интерфейс OpenWrt.
* **Интерактивный дашборд**: Графика задержек, управление подписками, правилами, клиентами и компонентами в несколько кликов.
* **Встроенный модал Фаззера стратегий**: Интерактивный запуск бенчмарков с прогресс-баром, зелёными бейджами успешности (`HTTP 204` / `HTTP 200`), индикацией рабочих эндпоинтов (`3/3 endpoints OK`) и выбором `🏆 Best Match`.
* **Потоковый терминал установки**: Живой вывод логов процессов установки и обновлений компонентов без зависаний страницы.
* **Динамические ссылки на репозитории**: Карточки компонентов ведут прямо на GitHub установленного варианта (extended, tiny, lx, stable).
* **Commit-level отслеживание обновлений**: Оповещения о свежих коммитах в рамках текущего релиза и безопасный откат версий (`component_rollback`).

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🛠️ Справочник консоли (CLI & REST Agent API)

<div align="center">

![CLI & API Showcase](assets/readme/cli_showcase.svg)

</div>

```bash
# === Фаззер и тестирование стратегий обхода DPI ===
tachyon fuzzer_start youtube_suite zapret2      # Запуск бенчмарка для YouTube на Zapret2
tachyon fuzzer_start discord_suite zapret2      # Запуск бенчмарка для Discord (голос + UDP)
tachyon fuzzer_status                           # Текущий прогресс и результаты фаззера (JSON)
tachyon fuzzer_stop                             # Немедленная остановка фаззера и очистка Netfilter
tachyon fuzzer_apply <strategy_id>              # Применение найденной стратегии в конфигурацию UCI

# === Тестирование DNS и Сетевой стек ===
tachyon dns_benchmark                           # Замер задержки и доступности DNS-резолверов
tachyon dns_autotune --apply                    # Автоматический выбор и применение лучшего DNS
tachyon test_rule google.com                    # Проверка, под какое правило маршрутизации попадает домен

# === Системная и офлайн-диагностика ===
tachyon doctor                                  # Запуск локальной диагностики без LLM
tachyon ai_doctor                               # Запуск анализа AI Doctor (с LLM)
tachyon ai_doctor_last                          # Просмотр последнего сохранённого отчёта ИИ
tachyon apply_quick_fix clear_dns_cache         # Применение выбранного кода исправления
tachyon diagnose_json                           # Вывод полного снимка состояния в формате JSON

# === Аварийное восстановление интернета ===
tachyon restore_native_internet                 # Мгновенная остановка прокси и возврат чистого WAN

# === Управление Telegram-ботом ===
tachyon telegram_status                         # Проверка статуса демона Telegram-бота
tachyon telegram_diagnose                       # 8-этапная диагностика подключения бота (JSON)
tachyon telegram_start                          # Запуск воркера Telegram-бота
tachyon telegram_stop                           # Остановка воркера Telegram-бота

# === Снапшоты и резервные копии ===
tachyon snapshot_list                           # Список сохранённых снимков конфигурации
tachyon snapshot_save my_working_setup          # Создание именованного снапшота
tachyon snapshot_restore /etc/config/snap.json  # Восстановление конфигурации из снимка
tachyon backup                                  # Создание полного архива конфигурации

# === Обновление списков и подписок ===
tachyon list_update                             # Принудительное обновление списков доменов/IP
tachyon subscription_update                     # Обновление всех прокси-подписок
tachyon hosts_list_update                       # Загрузка и обновление сторонних Hosts-листов

# === Управление службами и Watchdog ===
tachyon ai_heal                                 # Принудительный цикл самовосстановления
tachyon ai_status                               # Краткий статус Watchdog
tachyon ai_status_full                          # Расширенные метрики Watchdog (JSON)

# === Генераторы профилей ===
tachyon generate_warp                           # Генерация конфигурации Cloudflare WARP
tachyon generate_reality_keypair                # Генерация пары ключей для VLESS Reality

# === Интеграция с ИИ (MCP & HTTP REST API) ===
tachyon mcp                                     # Запуск Model Context Protocol сервера (stdio)
curl http://192.168.1.1/cgi-bin/tachyon-agent/health
curl http://192.168.1.1/cgi-bin/tachyon-agent/openapi.json
```

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 💻 Установка

<div align="center">

![Installation Terminal](assets/readme/install_terminal.svg)

</div>

Для установки Tachyon выполните следующую команду в SSH-консоли вашего роутера:

```bash
wget -O /tmp/tachyon-setup.sh https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
```

> [!TIP]
> **Зеркала установки (при блокировке или замедлении GitHub):**
> ```bash
> # Зеркало 1 (jsdelivr.net CDN):
> wget -O /tmp/tachyon-setup.sh https://cdn.jsdelivr.net/gh/Dushnilin/tachyon@main/install.sh && sh /tmp/tachyon-setup.sh
> 
> # Зеркало 2 (gh-proxy.com):
> wget -O /tmp/tachyon-setup.sh https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
> 
> # Зеркало 3 (ghfast.top):
> wget -O /tmp/tachyon-setup.sh https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
> ```

> [!NOTE]
> **Автоматическая миграция:** Конфигурации от **Forkop**, **Podkop Plus** и оригинального **Podkop** полностью совместимы. Инсталлятор автоматически перенесет ваши правила в `/etc/config/tachyon` без потери данных.

### 🗑️ Удаление (Clean Uninstall & Backup)

Для полного и чистого удаления Tachyon с возвратом штатного DNS, очисткой правил nftables и сохранением вашей конфигурации в `/etc/config/tachyon.backup-<timestamp>`:

```bash
wget -O /tmp/tachyon-uninstall.sh https://raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh && sh /tmp/tachyon-uninstall.sh
```

*Через зеркала:*
```bash
# Зеркало 1 (jsdelivr.net CDN):
wget -O /tmp/tachyon-uninstall.sh https://cdn.jsdelivr.net/gh/Dushnilin/tachyon@main/uninstall.sh && sh /tmp/tachyon-uninstall.sh

# Зеркало 2 (gh-proxy.com):
wget -O /tmp/tachyon-uninstall.sh https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh && sh /tmp/tachyon-uninstall.sh
```

**Опции и флаги:**
* `-y`, `--yes` — автоматическое выполнение без интерактивного подтверждения.
* `-p`, `--purge` — полное удаление всех файлов вместе с конфигурациями и бэкапами.
* `--keep-binaries` — сохранить бинарники sing-box / zapret / byedpi.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🤝 Оригинальные проекты и благодарности

Tachyon опирается на фундаментальные разработки открытого сообщества:

* 🍴 **[Forkop (ushan0v)](https://github.com/ushan0v/forkop)** — прямой родительский проект (ранее Podkop Plus).
* 🐕 **[Podkop (itdoginfo)](https://github.com/itdoginfo/podkop)** — оригинальный проект, заложивший основу архитектуры.
* 📦 **[sing-box](https://github.com/SagerNet/sing-box)** — универсальная прокси-платформа.
* 🚀 **[zapret (bol-van)](https://github.com/bol-van/zapret2)** — средства локального обхода DPI (`nfqws` / `nfqws2`).
* 🌐 **[ByeDPI](https://github.com/hrbrmstr/byedpi)** — локальный SOCKS-прокси для десинка пакетов.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 💖 Поддержать разработку

Если Tachyon помогает вам и делает работу в сети комфортной, вы можете поддержать проект и автора! ☕ 🧀 🌭

💳 **Карты РФ / СБП / Tinkoff Pay:**  
👉 [**Поддержать проект на CloudTips**](https://pay.cloudtips.ru/p/48c57581)

🪙 **Криптовалюта:**
* **Bitcoin (BTC):** `bc1q9ehdv7y9g948jejyflkq7xmau3tytgunxgh35h`
* **Ethereum (ETH / ERC-20):** `0x6CB7a4547eD62EF64990D5C6B5D9fdA58EB223E6`
* **TON:** `UQDPhLRjMz5KltDLACAT3YXXHDVEtIDOHky2i33ZIOtsMEoR`
* **Solana (SOL):** `3csTGaNeU9KjhCKHEKAU3XLS5UfVjEeBVhXihpsETZwh`

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

<div align="center">

![Tachyon Community Footer](assets/readme/footer_tachyon.svg)

</div>
