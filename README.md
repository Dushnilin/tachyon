<div align="center">

![Tachyon Banner](assets/readme/hero.svg)

[![Stars](https://img.shields.io/github/stars/Dushnilin/tachyon?style=for-the-badge&color=00F0FF)](https://github.com/Dushnilin/tachyon/stargazers)
[![Releases](https://img.shields.io/github/v/release/Dushnilin/tachyon?style=for-the-badge&color=818CF8)](https://github.com/Dushnilin/tachyon/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20SNAPSHOT-10B981?style=for-the-badge&logo=openwrt)](https://openwrt.org/)
[![License](https://img.shields.io/github/license/Dushnilin/tachyon?style=for-the-badge&color=C084FC)](LICENSE)

[**🇷🇺 Русский**](README.md) | [**🇬🇧 English**](README.en.md)

</div>

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## ⚡ О проекте

**Tachyon** — это высокопроизводительное, автономное и современное решение для оркестрации сетевого трафика, проксирования и обхода цензуры на роутерах под управлением **OpenWrt** (полная совместимость с **OpenWrt 23.05, 24.10, 25.x и SNAPSHOT**). Прямой форк проекта **[Forkop от @ushan0v](https://github.com/ushan0v/forkop)** (ранее **Podkop Plus**).

Tachyon объединяет ядро **sing-box**, средства локального аппаратного обхода DPI (**Zapret v1 / Zapret v2 / ByeDPI**), интерактивного **Telegram-бота**, а также инновационный **AI Stack** (автономный **AI Doctor v2.5** с офлайн-диагностикой и **HTTP REST Agent API / OpenAPI 3.0**).

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
3. **Zapret v2 (`nfqws2`)**: Адаптивный многовекторный обход ТСПУ (`multisplit`, `seqovl`, `wsize`) для YouTube 4K и Discord.
4. **ByeDPI (`ciadpi`)**: Локальный SOCKS5-десинхронизатор с фрагментацией полезной нагрузки HTTP/TLS SNI.
5. **Зашифрованный прокси-туннель (sing-box)**: Заблокированные ресурсы и приватный трафик направляются через защищённые протоколы (VLESS Reality, Hysteria2, WireGuard).

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🔥 Главные возможности и подсистемы

### 🛡️ 1. Мультипротокольное проксирование и локальный обход DPI
* **Ядро sing-box Engine (v1.11+)**: Нативная поддержка современных защищённых протоколов — **VLESS (Reality / gRPC / WS)**, **VMess**, **Shadowsocks**, **Trojan**, **Hysteria2**, **WireGuard / AmneziaWG**.
* **Локальный обход DPI без внешних VPS**: 
  * Встроенная интеграция с движками **Zapret v1 (`nfqws`)**, **Zapret v2 (`nfqws2`)** и **ByeDPI (`ciadpi`)** для аппаратной десинхронизации TCP-сегментов.
* **Многомерная селективная маршрутизация**: 
  * **По доменам и IP-сетям**: Направляйте через прокси или десинк только целевой трафик.
  * **По клиентским устройствам (MAC / IP)**: Раздельные правила для Smart TV, смартфонов, ПК и консолей.
  * **По GeoIP и странам**: Гибкие списки включения/исключения по странам назначения.
* **Автоматические подписки**: Фоновая загрузка, распарсинг и обновление прокси-нод по подписочным URL с авто-тестированием RTT задержки.

#### 🌐 Секции Hosts и Списки DNS-блокировок (Hosts Engine)
* **Статический DNS-Overriding (`dns_hosts`)**: Прямое переопределение IP-адресов для доменов в DNS-модуле sing-box и dnsmasq без необходимости подмены `/etc/hosts`.
* **Загрузка сторонних списков Hosts (`hosts_list_urls`)**: Автоматическая фоновая загрузка и интеграция внешних реестров и списков блокировок (AdAway, StevenBlack, РКН/Антизапрет списки).
* **Умный кэш (`combined.txt`)**: Автоматическое слияние, очистка и единое кэширование нескольких источников списков с поддержкой мгновенного переиспользования.
* **Резервирование через зеркала (GitHub Mirror Retry)**: При сетевых блокировках github.com модули загрузки автоматически переключаются на зеркала (`gh-proxy.com`, `ghproxy.net`).
* **Секции чистого Hosts (`action = hosts`)**: Создание изолированных правил перенаправления DNS без обязательной привязки к прокси-нодам.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🤖 2. ИИ-Доктор и HTTP REST Agent API (AI Stack v2.5)

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
  * Мгновенный возврат обычного интернета одной кнопкой в UI или командой `tachyon restore_native_internet`. Полная чистая остановка прокси и сброс nftables/ip rule без перезагрузки роутера.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 📱 3. Интерактивный Telegram-бот управления

<div align="center">

![Telegram Bot Showcase](assets/readme/telegram_bot_showcase.svg)

</div>

Полноценный пульт управления роутером из мессенджера:
* **Управление правилами «на лету»**: Просмотр списков обхода и добавление новых доменов или IP-сетей.
* **Мгновенный контроль секций**: Включение и отключение маршрутов одной кнопкой.
* **Переключение серверов**: Выбор активных прокси-нод с автоматическим замером задержки (RTT ping).
* **Управление устройствами LAN**: Просмотр активных клиентов и блокировка/разблокировка доступа по MAC-адресам.
* **Диагностика и Команды**: `/doctor`, `/ai_doctor`, `/fix <код>`, `/restart`, `/backup`, `/status`.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🛡️ 4. Watchdog — Защита и Самовосстановление

<div align="center">

![Watchdog Showcase](assets/readme/watchdog_showcase.svg)

</div>

Watchdog — сердце стабильности Tachyon. Работает каждые 5–15 секунд без внешних зависимостей:
* **Атомарные записи и UCI-бэкапы**: Запись конфигураций через `tmp` + `mv` предотвращает повреждение файлов при аварийном выключении питания.
* **Защита от зацикливания перезапусков (Restart-Loop Prevention)**: Лимит не более 3 перезапусков за 10 минут (`safe_proxy_restart()`), мьютекс `PROXY_RESTART_LOCK` и кулдаун DNS-петель.
* **Оптимизация памяти (OOM Watchdog)**: Динамическая регулировка `GOMEMLIMIT` при нехватке ОЗУ с отправкой уведомлений в Telegram.
* **Мягкая перезагрузка (Hot-Reload)**: Смена серверов и правил без разрыва активных TCP-соединений (Discord, онлайн-игры и стримы не прерываются).
* **Восстановление WAN и шлюзов**: Мониторинг сетевых интерфейсов и авто-поднятие при сбоях провайдера.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🖥️ 5. Современный Web-интерфейс LuCI (TypeScript)

<div align="center">

![LuCI Web UI Showcase](assets/readme/luci_web_showcase.svg)

</div>

* Полная интеграция в штатный Web-интерфейс OpenWrt.
* **Интерактивный дашборд**: Графика задержек, управление подписками, правилами и компонентами в несколько кликов.
* **Потоковый терминал установки**: Живой вывод логов процессов установки и обновлений компонентов без зависаний.
* **Динамические ссылки на репозитории**: Карточки компонентов ведут прямо на GitHub установленного варианта (extended, lx, stable).
* **Commit-level отслеживание обновлений**: Оповещения о свежих коммитах в рамках текущего релиза.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🛠️ Справочник консоли (CLI & REST Agent API)

<div align="center">

![CLI & API Showcase](assets/readme/cli_showcase.svg)

</div>

```bash
# === Системная и офлайн-диагностика ===
tachyon doctor                            # Запуск локальной диагностики без LLM
tachyon ai_doctor                         # Запуск анализа AI Doctor (с LLM)
tachyon ai_doctor_last                    # Просмотр последнего сохранённого отчёта ИИ
tachyon apply_quick_fix clear_dns_cache   # Применение выбранного кода исправления
tachyon diagnose_json                     # Вывод полного снимка в формате JSON

# === Аварийное восстановление интернета ===
tachyon restore_native_internet           # Мгновенная остановка прокси и возврат чистого WAN

# === Управление службами и Watchdog ===
tachyon ai_heal                           # Принудительный цикл самовосстановления
tachyon ai_status                         # Краткий статус Watchdog
tachyon ai_status_full                    # Расширенные метрики Watchdog

# === Проверка HTTP REST API ===
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
sh <(wget -O - https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh)
```

> [!TIP]
> **Зеркала установки (при блокировке или замедлении GitHub):**
> ```bash
> # Зеркало 1 (gh-proxy.com):
> sh <(wget -O - https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh)
> 
> # Зеркало 2 (ghfast.top):
> sh <(wget -O - https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh)
> ```

> [!NOTE]
> **Автоматическая миграция:** Конфигурации от **Forkop**, **Podkop Plus** и оригинального **Podkop** полностью совместимы. Инсталлятор автоматически перенесет ваши правила в `/etc/config/tachyon` без потери данных.

### 🗑️ Удаление (Clean Uninstall & Backup)

Для полного и чистого удаления Tachyon с возвратом штатного DNS, очисткой правил nftables и сохранением вашей конфигурации в `/etc/config/tachyon.backup-<timestamp>`:

```bash
sh <(wget -O - https://raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh)
```

*Через зеркало gh-proxy.com:*
```bash
sh <(wget -O - https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh)
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

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

<div align="center">

![Tachyon Community Footer](assets/readme/footer_tachyon.svg)

</div>
