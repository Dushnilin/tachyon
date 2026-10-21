# Tachyon AI & Agent API Integration

Tachyon предоставляет встроенные инструменты интеграции с искусственным интеллектом:
1. **AI Doctor** — автоматическая диагностика системы с участием LLM (OpenAI, Anthropic, DeepSeek или локальные/кастомные модели), обогащенная логами Watchdog, и поддержка цепочек быстрого исправления (Multi-Fix).
2. **HTTP REST Agent API & CLI** — программный интерфейс для внешних ИИ-агентов (Claude, GPT, Open-WebUI, Cursor, AutoGPT и т.д.).
3. **Автономный Watchdog** — работающая из коробки система самодиагностики и самовосстановления без внешних зависимостей.

---

## 1. AI Doctor (Встроенная LLM-диагностика)

AI Doctor собирает снимок состояния роутера (проверки sing-box, nftables, DNS, WAN, памяти, uptime, активные сбои Watchdog и 15 последних критических строк системного лога), передаёт его в выбранную LLM и выдаёт вердикт на русском языке. При наличии проблем AI Doctor генерирует цепочку кодов авто-исправления (`FIX: код1, код2`). Результат сохраняется в `/tmp/ai_doctor_last.json`.

### 1.1. Настройка AI Doctor

Настройка выполняется в LuCI Web UI (**Настройки → Дополнительные → AI Doctor**) или через UCI CLI:

```sh
# 1. Включить модуль AI Doctor
uci set tachyon.settings.enable_ai_doctor='1'

# 2. Выбрать провайдера: openai | anthropic | deepseek | custom
uci set tachyon.settings.ai_doctor_provider='openai'

# 3. Выказать модель (опционально - если пустое, используется дефолт провайдера)
uci set tachyon.settings.ai_doctor_model='gpt-4o-mini'

# 4. Указать API Key
uci set tachyon.settings.ai_doctor_api_key='sk-proj-...'

# 5. Для custom-провайдера (опционально)
uci set tachyon.settings.ai_doctor_custom_url='https://openrouter.ai/api/v1/chat/completions'

# Сохранить изменения
uci commit tachyon
```

### 1.2. Поддерживаемые провайдеры и модели

| Провайдер | UCI `ai_doctor_provider` | Модель по умолчанию | Примеры моделей (`ai_doctor_model`) |
|---|---|---|---|
| **OpenAI** | `openai` | `gpt-4o-mini` | `gpt-4o`, `gpt-4.1-mini`, `o4-mini` |
| **Anthropic** | `anthropic` | `claude-3-5-haiku-20241022` | `claude-3-5-sonnet-20241022`, `claude-3-7-sonnet-20250219` |
| **DeepSeek** | `deepseek` | `deepseek-chat` | `deepseek-reasoner` |
| **Gemini** | `gemini` | `gemini-2.5-flash` | `gemini-2.5-pro`, `gemini-1.5-flash` |
| **Custom API** | `custom` | `gpt-4o-mini` | Любая модель вашего сервера (`llama-3.3-70b`, `qwen-2.5-72b`) |

### 1.3. Коды быстрого исправления (Quick Fix Codes — 25 кодов)

Список совпадает с ветками `apply_quick_fix()` в `diagnostics/repairs.uc`. AI Doctor может вернуть один или несколько кодов через запятую. `start_steer` — алиас `start_singbox`, `restart_steer_dns` — алиас `restart_singbox_dns`.

1. `start_singbox` — `restore_dnsmasq` и перезапуск `/etc/init.d/tachyon-core`; для Steer — перезапуск `/etc/init.d/steer`
2. `rebuild_rules` — `/etc/init.d/tachyon reload`
3. `fix_dnsmasq` — перезапуск dnsmasq
4. `fix_resolv_symlink` — `ln -sf` на существующий `resolv.conf.auto` (`/tmp/resolv.conf.d/resolv.conf.auto`, иначе `/tmp/resolv.conf.auto`)
5. `start_watchdog` — перезапуск `/etc/init.d/tachyon`
6. `restart_singbox_dns` — перезапуск `/etc/init.d/tachyon-core`; для Steer — `reload_dnsd` и reload dnsmasq
7. `fix_uci_config` — восстановление UCI из `/etc/backup/tachyon_config`, иначе из `/etc/config/tachyon.bak`
8. `fix_wan_interface` — `ubus call network.interface.wan up`, `ifup wan`, сброс кэша маршрутов
9. `fix_gateway` — `/etc/init.d/network restart`
10. `clear_dns_cache` — перезапуск dnsmasq и сброс кэша маршрутов
11. `update_subscriptions` — `tachyon subscription_update_async`
12. `reset_firewall` — `/etc/init.d/firewall restart` и `/etc/init.d/tachyon reload`
13. `restart_network` — `/etc/init.d/network restart`
14. `restart_zapret` — остановка и отключение standalone zapret, zapret2 и byedpi, затем запуск runtime-провайдеров Tachyon
15. `optimize_memory` — сброс page cache, удаление `/tmp/tachyon-core/*.tmp`, перезапуск tachyon-core
16. `switch_to_doh` — `dns_type=doh`, commit, reload Tachyon
17. `heal_network_stack` — восстановление `/etc/resolv.conf`, перезапуск dnsmasq и Tachyon, `ifup wan`
18. `enable_safe_bypass` — `recovery_bypass=1`, commit, reload
19. `restore_native_internet` — остановка Tachyon, удаление таблицы nftables и policy routing, перезапуск dnsmasq
20. `fix_system_time` — `ntpd -q` и перезапуск sysntpd
21. `flush_conntrack` — `nf_conntrack_max=65536` и `conntrack -F`
22. `fix_bootstrap_dns` — `bootstrap_dns_server=77.88.8.8`, commit, reload
23. `restart_providers` — старт runtime WDTT, OlcRTC и FPTN
24. `optimize_mtu` — `tachyon discover-awg-mtu` и reload
25. `upgrade_to_singbox_extended` — `component_action_async sing_box install_extended`

Применение кодов из CLI:
```sh
tachyon apply_quick_fix clear_dns_cache,start_singbox
```

---

## 2. Автономная самодиагностика и Watchdog

Watchdog Tachyon работает автономно на роутере каждые 5–15 секунд без использования внешних API.

### Полезные CLI-команды:

```sh
tachyon ai_doctor          # запуск анализа AI Doctor (вызывает LLM и сохраняет в /tmp/ai_doctor_last.json)
tachyon ai_doctor_last     # получение последнего сохраненного отчета AI Doctor
tachyon apply_quick_fix    # выполнение кода(ов) быстрого исправления
tachyon ai_heal            # ручной запуск полного цикла авто-починки Watchdog
tachyon ai_status          # краткий JSON-статус Watchdog
tachyon ai_status_full     # полный JSON-статус с метриками и таймерами
tachyon doctor             # текстовый отчёт встроенного доктора (без LLM)
tachyon diagnose_json      # структурированный JSON отчёт для сторонних агентов
```

---

## 3. HTTP REST Agent API (для внешних ИИ-агентов)

Для работы внешних ИИ-агентов (Cursor, Open-WebUI, Claude Desktop, AutoGPT) Tachyon поднимает CGI эндпоинт через `uhttpd`:

```
http://<ip-роутера>/cgi-bin/tachyon-agent/<endpoint>
```

### 3.1. Настройка токена доступа (Agent API Token)

WRITE-операции (изменение настроек, перезапуск сервисов, применение фиксов) требуют Bearer-авторизации:

```sh
uci set tachyon.settings.agent_api_token='СЕКРЕТНЫЙ_ТОКЕН_АГЕНТА'
uci commit tachyon
```

### 3.2. Эндпоинты API

#### READ (Без авторизации в LAN):

| Метод | Путь | Описание |
|---|---|---|
| GET | `/cgi-bin/tachyon-agent/health` | Быстрая проверка работоспособности служб |
| GET | `/cgi-bin/tachyon-agent/snapshot` | Полный снимок системы для LLM |
| GET | `/cgi-bin/tachyon-agent/diagnose` | Результаты диагностики + предложения по ремонту |
| GET | `/cgi-bin/tachyon-agent/logs` | Последние 100 строк системного лога Tachyon |
| GET | `/cgi-bin/tachyon-agent/config` | Конфигурация UCI (секреты скрыты) |
| GET | `/cgi-bin/tachyon-agent/tools` | Схема инструментов в формате OpenAI Function Calling / MCP |
| GET | `/cgi-bin/tachyon-agent/ai-doctor/last` | Последний отчёт AI Doctor с меткой времени |

#### WRITE (Обязателен заголовок `Authorization: Bearer <токен>`):

| Метод | Путь | Тело запроса | Описание |
|---|---|---|---|
| POST | `/cgi-bin/tachyon-agent/heal` | `{}` | Принудительный запуск авто-ремонта |
| POST | `/cgi-bin/tachyon-agent/ai-doctor/fix` | `{"fix":"clear_dns_cache,start_singbox"}` | Применение кодов исправления |
| POST | `/cgi-bin/tachyon-agent/restart` | `{"service":"singbox"}` | Перезапуск службы (`singbox`, `watchdog`, `dnsmasq`) |
| POST | `/cgi-bin/tachyon-agent/reload` | `{}` | Перезагрузка правил и конфигурации |
| POST | `/cgi-bin/tachyon-agent/config/set` | `{"section":"settings","option":"dns_type","value":"doh"}` | Изменение параметров UCI |
| POST | `/cgi-bin/tachyon-agent/section/toggle` | `{"section":"имя_секции"}` | Включение / выключение правил обхода |
| POST | `/cgi-bin/tachyon-agent/domain/add` | `{"section":"имя_секции","domain":"example.com"}` | Добавление домена в списки |

---

## 4. Примеры вызовов и интеграции

### 4.1. Примеры cURL

```sh
# Проверка здоровья
curl http://192.168.1.1/cgi-bin/tachyon-agent/health

# Получение последнего отчёта AI Doctor
curl http://192.168.1.1/cgi-bin/tachyon-agent/ai-doctor/last | jq .

# Применение исправления от ИИ с токеном
curl -X POST \
  -H "Authorization: Bearer СЕКРЕТНЫЙ_ТОКЕН_АГЕНТА" \
  -H "Content-Type: application/json" \
  -d '{"fix":"clear_dns_cache,start_singbox"}' \
  http://192.168.1.1/cgi-bin/tachyon-agent/ai-doctor/fix
```

### 4.2. CLI вызовы через SSH

```sh
# Вызов AI Doctor
tachyon ai_doctor

# Вызов последнего отчета
tachyon ai_doctor_last

# Выполнение фиксов
tachyon apply_quick_fix clear_dns_cache
```

---

## 5. Безопасность

- **READ-эндпоинты** не передают пароли, приватные ключи подписчиков и бот-токены.
- **WRITE-эндпоинты** всегда блокируются без валидного Bearer-токена.
- **По умолчанию WAN-доступ к HTTP API закрыт** брандмауэром OpenWrt.