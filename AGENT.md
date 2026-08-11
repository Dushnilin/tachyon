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
| **Custom API** | `custom` | `gpt-4o-mini` | Любая модель вашего сервера (`llama-3.3-70b`, `qwen-2.5-72b`) |

### 1.3. Коды быстрого исправления (Quick Fix Codes — 13 кодов)

AI Doctor может вернуть один или несколько кодов быстрого исправления через запятую:

1. `start_singbox` — перезапуск упавшего сервиса sing-box
2. `rebuild_rules` — пересборка и сброс nftables-правил фильтрации
3. `fix_dnsmasq` — перезапуск и восстановление службы dnsmasq
4. `fix_resolv_symlink` — исправление повреждённого символического звена `/etc/resolv.conf`
5. `start_watchdog` — перезапуск службы Watchdog
6. `restart_singbox_dns` — перезапуск DNS-модуля sing-box при сбое ответов
7. `fix_uci_config` — восстановление конфигурации Tachyon из бэкапа
8. `fix_wan_interface` — перезапуск сетевого интерфейса WAN (`ifup wan`)
9. `fix_gateway` — перезапуск сетевого стека для восстановления системного шлюза
10. `clear_dns_cache` — очистка кэша DNS и база данных sing-box `cache.db`
11. `update_subscriptions` — принудительный запуск обновления прокси-подписок
12. `reset_firewall` — полный перезапуск фаервола роутера (`/etc/init.d/firewall restart`)
13. `restart_network` — полный перезапуск сетевой службы (`/etc/init.d/network restart`)

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