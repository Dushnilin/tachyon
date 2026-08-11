<div align="center">

![Tachyon Banner](assets/readme/hero.svg)

[![Stars](https://img.shields.io/github/stars/Dushnilin/tachyon?style=for-the-badge&color=38BDF8)](https://github.com/Dushnilin/tachyon/stargazers)
[![Releases](https://img.shields.io/github/v/release/Dushnilin/tachyon?style=for-the-badge&color=818CF8)](https://github.com/Dushnilin/tachyon/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20SNAPSHOT-10B981?style=for-the-badge&logo=openwrt)](https://openwrt.org/)
[![License](https://img.shields.io/github/license/Dushnilin/tachyon?style=for-the-badge&color=C084FC)](LICENSE)

[**🇷🇺 Русский**](README.md) | [**🇬🇧 English**](README.en.md)

</div>

---

## ⚡ О проекте

**Tachyon** — это продвинутое, автономное и современное решение для оркестрации сетевого трафика, проксирования и обхода цензуры на роутерах под управлением **OpenWrt** (полная поддержка всех версий **OpenWrt 23.05, 24.10, 25.x и SNAPSHOT**). Прямой форк проекта **[Forkop от @ushan0v](https://github.com/ushan0v/forkop)** (ранее **Podkop Plus**).

Проект объединяет в себе мощь **sing-box**, локальные средства обхода DPI (**Zapret v1 / Zapret v2 / ByeDPI**), интерактивного **Telegram-бота**, а также инновационный **AI Stack** (автономный **AI Doctor** и **HTTP REST Agent API / OpenAPI 3.0**).

Вся бэкенд-логика написана на скриптовом языке **ucode** — нативном движке OpenWrt, что гарантирует мгновенный отклик и минимальное потребление RAM (от 128 МБ ОЗУ).

---

## 🔥 Главные возможности и архитектура

### 🛡️ 1. Мультипротокольное проксирование и локальный обход DPI
* **Ядро sing-box Engine**: Нативная поддержка современных защищённых протоколов — **VLESS (Reality / gRPC / WS)**, **VMess**, **Shadowsocks**, **Trojan**, **WireGuard**.
* **Локальный обход DPI без внешних VPS**: 
  * Встроенная интеграция с движками **Zapret v1 (`nfqws`)**, **Zapret v2 (`nfqws2`)** и **ByeDPI (`ciadpi`)** для локальной десинхронизации пакетов на роутере.
* **Многомерная селективная маршрутизация**: 
  * **По доменам и IP-сетям**: Направляйте через прокси или десинк только целевой трафик.
  * **По клиентским устройствам (MAC / IP)**: Раздельные правила для Smart TV, смартфонов, ПК и консолей.
  * **По GeoIP и странам**: Гибкие списки включения/исключения по странам назначения.
* **Автоматические подписки**: Фоновая загрузка, распарсинг и обновление прокси-нод по подписочным URL.

---

### 🤖 2. ИИ-Доктор и HTTP REST Agent API (AI Stack)
* **Tachyon AI Doctor (v2)**: Умная диагностика роутера с использованием LLM (**OpenAI**, **Anthropic Claude**, **DeepSeek** или локальных моделей через OpenRouter / Ollama).
  * **Глубокий контекст**: Передаёт в модель не только текущие проверки, но и метрики Watchdog (OOM, серии сбоев) и последние сжатые логи роутера.
  * **Многокомпонентные цепочки фиксов (Multi-Fix)**: Возвращает цепочку автоматических исправлений с кнопками для каждого фикса и кнопкой «Исправить всё».
  * **13 встроенных Quick Fix кодов**: Авто-ремонт sing-box, nftables, dnsmasq, resolv.conf, очистка кэша DNS, обновление подписок и перезапуск сетевого стека.
  * **Языковые режимы**: Выбор языка вердикта (`ru` / `en`).
* **🤖 Вызов из Telegram-бота (`/ai_doctor` & `/fix`)**:
  * Запуск ИИ-диагностики прямо из мессенджера одной командой `/ai_doctor` с выведением кнопок моментального исправления.
* **🌐 HTTP REST Agent API & OpenAPI 3.0 (Swagger)**:
  * Безопасный REST API по адресу `/cgi-bin/tachyon-agent/` с авторизацией Bearer-токеном (`agent_api_token`).
  * Спецификация **OpenAPI 3.0.3** (`GET /cgi-bin/tachyon-agent/openapi.json`) для мгновенного подключения к **ChatGPT Custom GPTs**, N8N, Dify, Flowise и автономным ИИ-агентам (Cursor, AutoGPT, Claude Code).

---

### 📱 3. Интерактивный Telegram-бот управления
Полноценный пульт управления роутером из мессенджера:
* **Управление правилами «на лету»**: Просмотр списков обхода и добавление новых доменов или IP-сетей.
* **Мгновенный контроль секций**: Включение и отключение маршрутов одной кнопкой.
* **Переключение серверов**: Выбор активных прокси-нод с автоматическим замером задержки (RTT ping).
* **Управление устройствами LAN**: Просмотр активных клиентов и блокировка/разблокировка доступа по MAC-адресам.
* **Диагностика и Команды**: `/doctor`, `/ai_doctor`, `/fix <код>`, `/restart`, `/backup`.

---

### 🛡️ 4. Watchdog — Защита и Самовосстановление
Watchdog — сердце стабильности Tachyon. Работает каждые 5–15 секунд без внешних зависимостей:
* **Атомарные записи и UCI-бэкапы**: Запись конфигураций через `tmp` + `mv` предотвращает повреждение файлов при аварийном выключении питания.
* **Защита от зацикливания перезапусков (Restart-Loop Prevention)**: Лимит не более 3 перезапусков за 10 минут (`safe_proxy_restart()`), мьютекс `PROXY_RESTART_LOCK` и кулдаун DNS-петель.
* **Оптимизация памяти (OOM Watchdog)**: Динамическая регулировка `GOMEMLIMIT` при нехватке ОЗУ с отправкой уведомлений в Telegram.
* **Мягкая перезагрузка (Hot-Reload)**: Смена серверов и правил без разрыва активных TCP-соединений (Discord, онлайн-игры и стримы не прерываются).
* **Восстановление WAN и шлюзов**: Мониторинг сетевых интерфейсов и авто-поднятие при сбоях провайдера.

---

### 🖥️ 5. Современный Web-интерфейс LuCI (TypeScript)
* Полная интеграция в штатный Web-интерфейс OpenWrt.
* **Интерактивный дашборд**: Графика задержек, управление подписками, правилами и компонентами в несколько кликов.
* **Динамические ссылки на репозитории**: Карточки компонентов ведут прямо на GitHub установленного варианта (extended, lx, stable).
* **Commit-level отслеживание обновлений**: Оповещения о свежих коммитах в рамках текущего релиза.

---

## 🛠️ Справочник консоли (CLI & API Quick Reference)

```bash
# === Системная диагностика ===
tachyon doctor                            # Запуск локальной диагностики без LLM
tachyon ai_doctor                         # Запуск анализа AI Doctor (с LLM)
tachyon ai_doctor_last                    # Просмотр последнего сохранённого отчёта ИИ
tachyon apply_quick_fix clear_dns_cache   # Применение выбранного кода исправления
tachyon diagnose_json                     # Вывод полного снимка в формате JSON

# === Управление службами и Watchdog ===
tachyon ai_heal                           # Принудительный цикл самовосстановления
tachyon ai_status                         # Краткий статус Watchdog
tachyon ai_status_full                    # Расширенные метрики Watchdog

# === Проверка HTTP REST API ===
curl http://192.168.1.1/cgi-bin/tachyon-agent/health
curl http://192.168.1.1/cgi-bin/tachyon-agent/openapi.json
```

---

## 💻 Установка

Для установки Tachyon выполните следующую команду в SSH-консоли вашего роутера:

```bash
sh <(wget -O - https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh)
```

> [!NOTE]
> **Автоматическая миграция:** Конфигурации от **Forkop**, **Podkop Plus** и оригинального **Podkop** полностью совместимы. Инсталлятор автоматически перенесет ваши правила в `/etc/config/tachyon` без потери данных.

---

## 🤝 Оригинальные проекты и благодарности

Tachyon опирается на фундаментальные разработки открытого сообщества:

* 🍴 **[Forkop (ushan0v)](https://github.com/ushan0v/forkop)** — прямой родительский проект (ранее Podkop Plus).
* 🐕 **[Podkop (itdoginfo)](https://github.com/itdoginfo/podkop)** — оригинальный проект, заложивший основу архитектуры.
* 📦 **[sing-box](https://github.com/SagerNet/sing-box)** — универсальная прокси-платформа.
* 🚀 **[zapret (bol-van)](https://github.com/bol-van/zapret2)** — средства локального обхода DPI (`nfqws` / `nfqws2`).
* 🌐 **[ByeDPI](https://github.com/hrbrmstr/byedpi)** — локальный SOCKS-прокси для десинка пакетов.

---

## 💖 Поддержать разработку

Если Tachyon помогает вам и делает работу в сети комфортной, вы можете поддержать проект и автора! ☕ 🧀 🌭

💳 **Карты РФ / СБП / Tinkoff Pay:**  
👉 [**Поддержать проект на CloudTips**](https://pay.cloudtips.ru/p/48c57581)

---

<div align="center">

Made with ❤️ for OpenWrt Community

</div>
