# Tachyon AI Agent API

Tachyon поддерживает подключение внешних ИИ-агентов (Claude, GPT, Open-WebUI, Cursor и т.д.) через встроенный HTTP REST API и CLI-интерфейс.

## Самодиагностика и самовосстановление (из коробки)

Watchdog Tachyon уже работает автономно: каждые 5–15 секунд он проверяет состояние всех подсистем и автоматически исправляет проблемы. Для принудительного запуска диагностики и восстановления:

```sh
tachyon ai_heal          # полный цикл диагностики + авто-починки
tachyon ai_status        # текущий JSON-статус watchdog
tachyon ai_status_full   # расширенный JSON с метриками
tachyon doctor           # текстовый отчёт доктора
tachyon diagnose_json    # структурированный JSON для ИИ-агента
```

---

## HTTP REST API (для ИИ-агентов)

После установки Tachyon поднимает CGI-эндпоинт через uhttpd:

```
http://<ip-роутера>/cgi-bin/tachyon-agent/<endpoint>
```

### Настройка токена (обязательна для WRITE-операций)

```sh
uci set tachyon.settings.agent_api_token='ВАШ_СЕКРЕТНЫЙ_ТОКЕН'
uci commit tachyon
```

Без токена READ-эндпоинты работают свободно с локальной сети. WRITE-эндпоинты всегда требуют `Authorization: Bearer <token>`.

---

## Эндпоинты

### READ (без токена)

| Метод | Путь | Описание |
|---|---|---|
| GET | `/cgi-bin/tachyon-agent/health` | Быстрый статус служб |
| GET | `/cgi-bin/tachyon-agent/snapshot` | Полный снимок системы для LLM |
| GET | `/cgi-bin/tachyon-agent/diagnose` | Диагностика + автоисправление |
| GET | `/cgi-bin/tachyon-agent/logs` | Последние 100 строк лога |
| GET | `/cgi-bin/tachyon-agent/config` | Конфигурация UCI (секреты скрыты) |
| GET | `/cgi-bin/tachyon-agent/tools` | JSON-схема инструментов для LLM |

### WRITE (Bearer token обязателен)

| Метод | Путь | Тело | Описание |
|---|---|---|---|
| POST | `/cgi-bin/tachyon-agent/heal` | `{}` | Авто-диагностика и ремонт |
| POST | `/cgi-bin/tachyon-agent/restart` | `{"service":"singbox"}` | Перезапуск службы |
| POST | `/cgi-bin/tachyon-agent/reload` | `{}` | Перезагрузка конфигурации |
| POST | `/cgi-bin/tachyon-agent/config/set` | `{"section":"settings","option":"dns_type","value":"doh"}` | Установить UCI-опцию |
| POST | `/cgi-bin/tachyon-agent/section/toggle` | `{"section":"myrule"}` | Вкл/выкл секцию |
| POST | `/cgi-bin/tachyon-agent/domain/add` | `{"section":"myrule","domain":"example.com"}` | Добавить домен |

---

## Примеры curl

```sh
# Быстрый статус
curl http://192.168.1.1/cgi-bin/tachyon-agent/health

# Полный снимок системы
curl http://192.168.1.1/cgi-bin/tachyon-agent/snapshot | jq .

# Запуск диагностики и авто-починки
curl http://192.168.1.1/cgi-bin/tachyon-agent/diagnose | jq .

# Принудительный heal с токеном
curl -X POST \
  -H "Authorization: Bearer ВАШ_ТОКЕН" \
  http://192.168.1.1/cgi-bin/tachyon-agent/heal

# Перезапуск sing-box
curl -X POST \
  -H "Authorization: Bearer ВАШ_ТОКЕН" \
  -H "Content-Type: application/json" \
  -d '{"service":"singbox"}' \
  http://192.168.1.1/cgi-bin/tachyon-agent/restart
```

---

## CLI через SSH

Для ИИ-агентов с SSH-доступом:

```sh
# Полный диагностический JSON
tachyon diagnose_json

# Вызов любого эндпоинта
tachyon agent /tachyon/agent/v1/health GET
tachyon agent /tachyon/agent/v1/snapshot GET
tachyon agent /tachyon/agent/v1/diagnose GET
tachyon agent /tachyon/agent/v1/heal POST '{}' 'Bearer ВАШ_ТОКЕН'
tachyon agent /tachyon/agent/v1/restart POST '{"service":"singbox"}' 'Bearer ВАШ_ТОКЕН'
```

---

## Подключение к Claude / Open-WebUI / Cursor

### 1. Получить схему инструментов

```sh
curl http://192.168.1.1/cgi-bin/tachyon-agent/tools
```

Ответ содержит массив `tools` в формате OpenAI Function Calling / MCP.

### 2. Системный промпт для ИИ-агента

```
You are a network assistant connected to a Tachyon OpenWrt router.
Router API base: http://192.168.1.1/cgi-bin/tachyon-agent/
Authorization token for write operations: Bearer <ВАШ_ТОКЕН>

Start by calling GET /snapshot to understand the current system state.
Then call GET /diagnose to check for problems.
Use the tools listed at GET /tools to interact with the system.
```

### 3. Через Open-WebUI с MCP

Добавьте URL инструментов в конфигурацию Open-WebUI:
```
http://192.168.1.1/cgi-bin/tachyon-agent/tools
```

---

## Безопасность

- **READ-эндпоинты** доступны с локальной сети без токена (данные не содержат секретов)
- **WRITE-эндпоинты** всегда требуют Bearer-токен
- Токен хранится в UCI: `tachyon.settings.agent_api_token`
- Внешний (WAN) доступ закрыт фаерволом OpenWrt по умолчанию
- Для удалённого доступа используйте SSH-туннель:
  ```sh
  ssh -L 8080:192.168.1.1:80 root@ваш-роутер
  curl http://localhost:8080/cgi-bin/tachyon-agent/health
  ```