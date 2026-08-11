# Tachyon AI & Agent API Integration

Tachyon предоставляет встроенные инструменты интеграции с искусственным интеллектом:
1. **AI Doctor** — автоматическая диагностика системы с участием LLM (OpenAI, Anthropic, DeepSeek или локальные/кастомные модели) и кнопками быстрого исправления (Quick Fix).
2. **HTTP REST Agent API & CLI** — программный интерфейс для внешних ИИ-агентов (Claude, GPT, Open-WebUI, Cursor, AutoGPT и т.д.).
3. **Автономный Watchdog** — работающая из коробки система самодиагностики и самовосстановления без внешних зависимостей.

---

## 1. AI Doctor (Встроенная LLM-диагностика)

AI Doctor собирает снимок состояния роутера (проверки sing-box, nftables, DNS, WAN, памяти, uptime и процессов), передаёт его в выбранную LLM и выдаёт краткий вердикт на русском языке. При наличии устранимой проблемы AI Doctor генерирует код быстрого исправления (`FIX: <код>`).

### 1.1. Настройка AI Doctor

Настройка выполняется в LuCI Web UI (**Настройки → Дополнительные → AI Doctor**) или через UCI CLI:

```sh
# 1. Включить модуль AI Doctor
uci set tachyon.settings.enable_ai_doctor='1'

# 2. Выбрать провадера: openai | anthropic | deepseek | custom
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

| Провайдер | UCI `ai_doctor_provider` | Модель по умолчанию (если `ai_doctor_model` пустое) | Примеры моделей (`ai_doctor_model`) |
|---|---|---|---|
| **OpenAI** | `openai` | `gpt-4o-mini` | `gpt-4o`, `gpt-4.1-mini`, `o4-mini` |
| **Anthropic** | `anthropic` | `claude-3-5-haiku-20241022` | `claude-3-5-sonnet-20241022`, `claude-3-7-sonnet-20250219` |
| **DeepSeek** | `deepseek` | `deepseek-chat` | `deepseek-reasoner` |
| **Custom API** | `custom` | `gpt-4o-mini` | Название любой модели вашего сервера (например `llama-3.3-70b`, `qwen-2.5-72b`) |

### 1.3. Коды быстрого исправления (Quick Fix Codes)

Если LLM находит известную проблему, она возвращает код быстрого исправления. Tachyon поддерживает следующие автоматические исправления:

- `start_singbox` — перезапуск упавшего сервиса sing-box
- `rebuild_rules` — пересборка и сброс nftables-правил фильтрации
- `fix_dnsmasq` — восстановление корректной конфигурации dnsmasq
- `fix_resolv_symlink` — исправление повреждённого символического звена `/etc/resolv.conf`
- `start_watchdog` — запуск остановленного процесса Watchdog
- `restart_singbox_dns` — перезапуск DNS-модуля sing-box при сбое ответов
- `fix_uci_config` — восстановление повреждённого UCI-конфига Tachyon из бэкапа
- `fix_wan_interface` — перезапуск сбойного сетевого интерфейса WAN
- `fix_gateway` — исправление отсутствующего или некорректного системного шлюза

---

## 2. Автономная самодиагностика и Watchdog

Watchdog Tachyon работает автономно на роутере каждые 5–15 секунд без использования внешних API.

### Полезные CLI-команды:

```sh
tachyon ai_doctor          # запуск анализа AI Doctor (вызывает LLM)
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

WRITE-операции (изменение настроек, перезапуск сервисов) требуют Bearer-авторизации:

```sh
uci set tachyon.settings.agent_api_token='СЕКРЕТНЫЙ_ТОКЕН_АГЕНТА'
uci commit tachyon
```

### 3.2. Эндпоинты API

#### READ (Без авторизации в LAN):

| Метод | Путь | Описание |
|---|---|---|
| GET | `/cgi-bin/tachyon-agent/health` | Быстрая проверка работоспособности служб |
| GET | `/cgi-bin/tachyon-agent/snapshot` | Полный сним ок системы для LLM |
| GET | `/cgi-bin/tachyon-agent/diagnose` | Результаты диагностики + предложения по ремонту |
| GET | `/cgi-bin/tachyon-agent/logs` | Последние 100 строк системного лога Tachyon |
| GET | `/cgi-bin/tachyon-agent/config` | Конфигурация UCI (секреты скрыты) |
| GET | `/cgi-bin/tachyon-agent/tools` | Схема инструментов в формате OpenAI Function Calling / MCP |

#### WRITE (Обязателен заголовок `Authorization: Bearer <токен>`):

| Метод | Путь | Тело запроса | Описание |
|---|---|---|---|
| POST | `/cgi-bin/tachyon-agent/heal` | `{}` | Принудительный запуск авто-ремонта |
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

# Полный снимок системы для промпта LLM
curl http://192.168.1.1/cgi-bin/tachyon-agent/snapshot | jq .

# Вызов команды восстановления с токеном
curl -X POST \
  -H "Authorization: Bearer СЕКРЕТНЫЙ_ТОКЕН_АГЕНТА" \
  http://192.168.1.1/cgi-bin/tachyon-agent/heal

# Изменение настроек UCI через API
curl -X POST \
  -H "Authorization: Bearer СЕКРЕТНЫЙ_ТОКЕН_АГЕНТА" \
  -H "Content-Type: application/json" \
  -d '{"section":"settings","option":"ai_doctor_model","value":"gpt-4o"}' \
  http://192.168.1.1/cgi-bin/tachyon-agent/config/set
```

### 4.2. CLI вызовы через SSH

Для внешних агентов с SSH-доступом:

```sh
# Структурированный отчёт
tachyon diagnose_json

# Вызов API через внутреннюю утилиту agent
tachyon agent /tachyon/agent/v1/health GET
tachyon agent /tachyon/agent/v1/snapshot GET
tachyon agent /tachyon/agent/v1/heal POST '{}' 'Bearer СЕКРЕТНЫЙ_ТОКЕН_АГЕНТА'
```

### 4.3. Подключение к Cursor / Claude Desktop / Open-WebUI

1. **Запросить схему инструментов:**
   ```sh
   curl http://192.168.1.1/cgi-bin/tachyon-agent/tools
   ```
2. **Системный промпт для внешнего ИИ-агента:**
   ```text
   You are a network administrator AI agent connected to Tachyon OpenWrt router.
   Base API URL: http://192.168.1.1/cgi-bin/tachyon-agent/
   Auth Header for POST commands: Authorization: Bearer <YOUR_AGENT_API_TOKEN>

   1. Call GET /snapshot to read the current network state.
   2. Call GET /diagnose to check system issues.
   3. Execute actions using POST endpoints provided in GET /tools.
   ```

---

## 5. Безопасность

- **READ-эндпоинты** не передают пароли, приватные ключи подписчиков и бот-токены.
- **WRITE-эндпоинты** всегда блокируются без валидного Bearer-токена.
- **По умолчанию WAN-доступ к HTTP API закрыт** брандмауэром OpenWrt.
- Для удаленного управления рекомендуется использовать SSH-туннелирование:
  ```sh
  ssh -L 8080:192.168.1.1:80 root@router-ip
  ```