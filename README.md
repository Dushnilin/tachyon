<div align="center">

![Tachyon Banner](assets/readme/hero.svg)

[![Stars](https://img.shields.io/github/stars/Dushnilin/tachyon?style=for-the-badge&color=00F0FF)](https://github.com/Dushnilin/tachyon/stargazers)
[![Releases](https://img.shields.io/github/v/release/Dushnilin/tachyon?style=for-the-badge&color=818CF8)](https://github.com/Dushnilin/tachyon/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20SNAPSHOT-10B981?style=for-the-badge&logo=openwrt)](https://openwrt.org/)
[![Telegram](https://img.shields.io/badge/Telegram-Канал-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/tachyon_proxy)
[![Boosty](https://img.shields.io/badge/Boosty-Поддержать-FF6A00?style=for-the-badge&logo=boosty&logoColor=white)](https://boosty.to/tachyon)
[![License](https://img.shields.io/github/license/Dushnilin/tachyon?style=for-the-badge&color=C084FC)](LICENSE)

[**🇷🇺 Русский**](README.md) | [**🇬🇧 English**](README.en.md)

</div>

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## ⚡ О проекте

**Tachyon** — это высокопроизводительное, автономное и бескомпромиссное решение для оркестрации сетевого трафика, проксирования и обхода цензуры на роутерах под управлением **OpenWrt** (полная совместимость с **OpenWrt 23.05, 24.10, 25.x и SNAPSHOT**). Прямой форк проектов **[Forkop от @ushan0v](https://github.com/ushan0v/forkop)** (ранее **Podkop Plus**) и **[Steer от @xyzmean](https://github.com/xyzmean/steer)**.

Tachyon объединяет мульти-движковую маршрутизацию (**sing-box**, легковесный **Steer** и гибридный **Steer-Extended**), нативную поддержку **OpenVPN (.ovpn)**, высокоскоростной протокол **FPTN** (Fast Packet Tunnel Network), средства локального аппаратного обхода DPI (**Zapret v1 / Zapret v2 / ByeDPI**), интерактивный комбинаторный **DPI Strategy Fuzzer v2**, защищённый **Telegram-бот управления**, а также инновационный **AI Stack** (автономный **AI Doctor v3.0**, офлайн-диагностику, **HTTP REST Agent API / OpenAPI 3.0** и **MCP Server** для подключения ИИ-агентов).

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
5. **Мульти-движковое туннелирование и прокси (sing-box / Steer / FPTN / OpenVPN)**: Заблокированные ресурсы и приватный трафик направляются через защищённые протоколы (VLESS Reality, Hysteria2, WireGuard, AmneziaWG, OpenVPN) или высокоскоростной туннель **FPTN** (`tun-fptn` поверх WebSocket/TLS с маскировкой под веб-трафик). На устройствах с малым объемом памяти активен **Steer** / **Steer-Extended**.
6. **Smart DNS Pipeline**: Изолированная обработка DNS через FakeIP (`198.18.0.0/15`), DoH/DoT/DoQ с защитой от перехвата провайдером, интеграцией SmartDNS/`steer-dnsd` и автоматическим отказоустойчивым переключением (DNS Failover).

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🔥 Главные возможности и подсистемы

### 🧭 1. Мульти-движковая маршрутизация (Multi-Engine Architecture)
* **Гибкий выбор движка маршрутизации**:
  * **sing-box Engine**: Полнофункциональный шлюз со всеми современными прокси-протоколами, селективной маршрутизацией по доменам/IP/устройствам и FakeIP.
  * **Steer Engine**: Ультралегковесный движок селективной маршрутизации на нативном `steer` и SmartDNS/DoH/DoT (`steer-dnsd`) для роутеров со скромным объёмом памяти.
  * **Steer-Extended Engine**: Гибридный режим — легковесный Steer в связке с аппаратным десинхронизатором Zapret (`nfqws`/`nfqws2`). Максимальная производительность и обход DPI без затрат ОЗУ на тяжелые Go-демоны.
* **Переключение движка в 1 клик**:
  * Интерактивная карточка Routing Engine в LuCI и CLI (`tachyon engine_set <name>`) с модальным окном реального прогресса переключения.
  * Автоматическая реконфигурация DNS (`smartdns`, `steer-dnsd`, `dnsmasq`), интерфейсов и правил nftables при смене движка.
* **Материализация списков и экспорт подписок (`sub.txt`)**:
  * Авто-генерация плоских списков `sub.txt` из подписок для VLESS-аутбаундов Steer.
  * Прямая загрузка и компиляция списков `.lst`/`.txt` в нативные `rule_set`.

---

### 🛡️ 2. Мультипротокольное проксирование и продвинутые подписки
* **Ядро sing-box Engine (v1.11 - v1.14+)**:
  * Нативная поддержка: **VLESS (Reality / gRPC / WS)**, **VMess**, **Shadowsocks**, **Trojan**, **Hysteria2**, **WireGuard / AmneziaWG (AWG 3.1)**.
  * **Нативный OpenVPN Endpoint и загрузка `.ovpn`**: Полноценный встроенный OpenVPN-клиент в sing-box (>= 1.14.0) с возможностью прямой загрузки и валидации файлов `.ovpn` в LuCI.
* **Высокоскоростной туннель FPTN Engine (`fptn-client-cli`)**:
  * L3-туннелирование IP-пакетов поверх WebSocket/TLS с маскировкой под стандартный HTTPS-трафик (`tun-fptn`, таблица маршрутизации `4249`).
* **Продвинутый движок подписок и Happ Crypt4**:
  * **Дешифрование Happ Crypt4**: Поддержка зашифрованных подписок провайдеров.
  * **Эмуляция Dual HWID**: Корректная подмена заголовков аппаратного идентификатора клиента.
  * **Пиннинг сертификатов (TLS Certificate SHA-256)**: Валидация хэшей сертификатов узлов (`pcs`).
  * **Anti-Collapse Shrink Guard**: Сохранение кэша рабочих нод при временных сбоях или пустых ответах серверов подписки.
* **Генератор профилей Cloudflare WARP / AmneziaWG (`generate_warp`)**.
* **Многомерная селективная маршрутизация**: по доменам, IP-сетям, MAC/IP клиентских устройств и странам (GeoIP).

---

### 🌐 3. Умный сетевой стек DNS, DoH/DoT и защита от утечек
* **FakeIP-пул (`198.18.0.0/15`)**: Мгновенный коннект без ожидания удалённого DNS.
* **Современные протоколы DNS**: DoH (HTTPS), DoT (TLS), DoQ (QUIC), DNS over HTTP/3.
* **Автономный DNS Failover (`dns_failover.uc`)**: Непрерывный мониторинг и бесшовное переключение апстримов.
* **Анти-перехват DNS**: Прозрачный перехват портов 53 UDP/TCP в ядре nftables.
* **Детектор утечек DNS (DNS Leak Checker)**: Встроенная проверка перехвата запросов провайдером.
* **Изоляция Multi-WAN и Tailscale**: Исключение внутренних туннелей и Tailscale (`100.64.0.0/10`) из проверок публичного WAN без ложных срабатываний.
* **Секции Hosts и Списки DNS-блокировок (Hosts Engine)**: Статическое переопределение IP (`dns_hosts`), загрузка сторонних реестров (AdAway, StevenBlack, Антизапрет) с автопереключением на зеркала (GitHub Mirror Retry: `jsdelivr`, `gh-proxy`).
* **Интерактивный DNS Benchmark (`tachyon dns_benchmark`)** с автотюнингом (`dns_autotune`).

---

### ⚡ 4. God-Tier Генератор и Фаззер стратегий обхода ТСПУ (DPI Fuzzer v2)
* **Модульная архитектура фаззера (`fuzzer/*`)**: Разделение на специализированные модули профилирования, раннера, бенчмаркинга и стратегий.
* **Фаззинг нового поколения (Probe v2 & Stable Scoring)**: Двухстадийная верификация, защищающая от ложноположительных срабатываний на нестабильных каналах.
* **Кураторские пресеты из zapret4rocket и homeproxy-hiddify**: Проверенные на практике стратегии против актуальных блокировок.
* **Поддержка стратегий Flowseal**: Интеграция паттернов Flowseal для стабильного обхода DPI.
* **Кастомные мульти-доменные цели**: Тестирование стратегий одновременно по набору целевых доменов пользователя.
* **PAWS TCP Timestamp Spoofing (`tcp_ts=-600000:tcp_ts_up`)**: RFC 7323 десинхронизация с устаревшими timestamp TCP.
* **Аутентичные бинарные дампы (Blobs)**: `tls_max`, `tls_google`, `tls_gosuslugi`, `tls_sber`, `quic_google`, `discord_udp` и др.
* **Точное перекрытие последовательностей (SeqOvl Pattern Overlap)** & **TCP SYN Data (`syndata`)**.
* **286+ стратегий Zapret2, 130 для Zapret v1, 65 для ByeDPI**.
* **Изолированная очередь nftables (`0x00200000`) & применение в 1 клик (`🏆 Best Match`)**.

---

### 🤖 5. ИИ-Доктор v3.0, REST Agent API и MCP Server (AI Stack)
<div align="center">

![AI Doctor Monitor](assets/readme/ai_doctor_showcase.svg)

</div>

* **Tachyon AI Doctor (v3.0)**: Глубокая модульная архитектура (`doctor.uc`, `repairs.uc`, `system_info.uc`, `routing.uc`, `dns.uc`).
  * Анализ через облачные LLM (**OpenAI**, **Claude**, **DeepSeek**) или локальные модели (через OpenRouter / Ollama).
  * **Схлопывание симптомов (Symptom Collapsing)**: Интеллектуальное объединение каскадных сбоев в первопричины.
* **14 встроенных кодов быстрого ремонта Quick Fix**:
  * Авто-ремонт sing-box, Steer, nftables, dnsmasq, resolv.conf.
  * Перезапуск провайдеров (`restart_providers`), очистка кэша DNS (`flush_dns`).
  * Синхронизация системного времени NTP (`fix_system_time`).
  * Сброс таблицы conntrack (`flush_conntrack`).
  * DNS dead-lock repair (`fix_bootstrap_dns`).
* **Конфликт-устойчивый откат и восстановление**: Автоматический откат к стабильной конфигурации при обнаружении ошибок синтаксиса dnsmasq или nftables.
* **🚨 Аварийное восстановление интернета (Native Internet Fallback)** (`tachyon restore_native_internet`).
* **🔌 Model Context Protocol (MCP) Server (`tachyon mcp`)**: Подключение роутера к Claude Desktop, Cursor, Antigravity через JSON-RPC 2.0 stdio.
* **🌐 HTTP REST Agent API (OpenAPI 3.0)**: Авторизация по Bearer token, асинхронный перезапуск (`async reload`) без разрыва HTTP-сессий, CGI-шлюз (`/cgi-bin/tachyon-api`).

---

### 📱 6. Интерактивный Telegram-бот управления
<div align="center">

![Telegram Bot Showcase](assets/readme/telegram_bot_showcase.svg)

</div>

* **Аутентификация Clash API**: Защищённое управление через Secret Token.
* **Расширенная телеметрия (`/info`)** и управление секциями и нодами прямо из мессенджера.
* **Мониторинг активных соединений (`/connections`)** с постраничным выводом и кнопкой сброса (`/close_connections`).
* **Выделенный воркер**: Grace period для heartbeat, защита от зомби-процессов и дублирования.
* **Тихие часы (`/qh`)** и управление устройствами LAN по MAC-адресам.
* **Команды**: `/doctor`, `/ai_doctor`, `/heal`, `/speed`, `/ping`, `/test`, `/logs`, `/info`, `/export_config`, `/restart`, `/lang`.

---

### 🛡️ 7. Watchdog, Процесс-менеджер и Транзакционная стабильность
<div align="center">

![Watchdog Showcase](assets/readme/watchdog_showcase.svg)

</div>

* **Процесс-менеджер с валидацией происхождения (PID Provenance & Identity)**: Модуль `core/process.uc` валидирует `pid`, `starttime` и `boot_id`, гарантируя, что системные демоны не затронут переиспользованные системой PID.
* **Транзакционный менеджер пакетов (`core/packages.uc`)**: Защита от stale lock, верификация ELF-сигнатур сжатых UPX бинарников, автоматическая очистка файла `world` в APK для разрешения конфликтов `PROVIDES/REPLACES` при обновлении пакетов.
* **Единый структурированный логгер (`core/logging.uc`)**: Ротируемые структурированные логи.
* **Защита от зацикливания перезапусков (Restart-Loop Prevention)**: Лимит 3 перезапусков за 10 минут, мьютекс `PROXY_RESTART_LOCK`.
* **Оптимизация памяти (OOM Watchdog)**: Динамическое управление `GOMEMLIMIT` с уведомлениями в Telegram.
* **Мягкая перезагрузка (Hot-Reload)** & **Снапшоты конфигурации (Snapshots & Rollback)** (`snapshot_save` / `snapshot_restore`).

---

### 👶 8. Родительский контроль, квоты и Smart QoS
* **Поустройственные расписания** интернет-доступа (часы и дни недели).
* **Квотирование трафика**: Лимиты входящего/исходящего трафика со сбросом по cron (`parental_quota.uc`).
* **Smart QoS & Priority Daemon**: DSCP-маркировка трафика в nftables для голоса, игр и стримов с предотвращением Bufferbloat.
* **Мгновенная изоляция**: Блокировка и разблокировка доступа устройства в 1 клик.

---

### 🖥️ 9. Современный Web-интерфейс LuCI (TypeScript)
<div align="center">

![LuCI Web UI Showcase](assets/readme/luci_web_showcase.svg)

</div>

* **Мониторинг ОЗУ в реальном времени**: Точное отображение потребления памяти процессами Tachyon и расчетного размера DNS-кэша dnsmasq прямо на дашборде.
* **Индикатор шагов обновления (Step Indicator)**: Наглядный пошаговый прогресс обновления списков вместо сырого лог-вывода.
* **Клонирование секций в 1 клик ("Copy")**: Быстрое дублирование сложных правил обхода.
* **Управление движками**: Переключение `sing-box` / `steer` / `steer-extended` с информативным модальным окном.
* **Загрузчик файлов `.ovpn`** для OpenVPN-секций.
* **Встроенный модал Фаззера стратегий** с прогресс-баром, HTTP-статусами и `🏆 Best Match`.
* **Потоковый терминал установки и отката версий компонентов**.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🛠️ Справочник консоли (CLI & REST Agent API)

<div align="center">

![CLI & API Showcase](assets/readme/cli_showcase.svg)

</div>

```bash
# === Управление движками маршрутизации (Multi-Engine) ===
tachyon engine_list                             # Список доступных движков (sing-box, steer, steer-extended)
tachyon engine_get                              # Текущий активный движок
tachyon engine_set <sing-box|steer|steer-extended> # Переключение движка с автоматической реконфигурацией
tachyon engine_status                           # Расширенный статус активного движка (JSON)

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
tachyon telegram_diagnose                       # Диагностика подключения бота (JSON)
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
curl http://192.168.1.1/cgi-bin/tachyon-api/health
curl http://192.168.1.1/cgi-bin/tachyon-api/openapi.json
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
* 🧭 **[steer (xyzmean)](https://github.com/xyzmean/steer)** — оригинальный проект легковесной policy-based маршрутизации и обхода блокировок для OpenWrt, интегрированный в Multi-Engine ядро Tachyon.
* 📦 **[sing-box](https://github.com/SagerNet/sing-box)** — универсальная прокси-платформа.
* 🚀 **[zapret (bol-van)](https://github.com/bol-van/zapret2)** — средства локального обхода DPI (`nfqws` / `nfqws2`).
* 🌐 **[ByeDPI](https://github.com/hrbrmstr/byedpi)** — локальный SOCKS-прокси для десинка пакетов.
* 🛡️ **[FPTN (fptn-project)](https://github.com/fptn-project/fptn)** — высокоскоростной VPN/туннель пакетов через WebSocket/TLS с обходом блокировок.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 💖 Поддержать разработку

Если Tachyon помогает вам и делает работу в сети комфортной, вы можете поддержать проект и автора! ☕ 🧀 🌭

⭐ **Boosty (подписки, донаты, эксклюзив):**  
👉 [**Поддержать на Boosty**](https://boosty.to/tachyon)

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
