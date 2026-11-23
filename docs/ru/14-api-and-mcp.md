# Agent REST API и MCP-сервер

[English](../en/14-api-and-mcp.md) | [К оглавлению](README.md)

Tachyon 2.0 предоставляет машиночитаемый **Agent REST API** и полноценный сервер **Model Context Protocol (MCP)** по протоколу JSON-RPC 2.0 для автоматизации, внешнего мониторинга и подключения ИИ-агентов (например, к вашим рабочим средам разработки или домашней автоматизации).

## Аутентификация и безопасность (`src/api.rs`)

Запросы к API и HTTP-эндпоинту MCP проходят проверку доступа:

1. **Bearer-токен Agent API**: передайте заголовок `Authorization: Bearer <agent_api_token>`, где токен настроен в `settings.agent_api_token`. Секретные ключи в ответах API автоматически редактируются как `[REDACTED]`.
2. **Сессия веб-интерфейса**: cookie `tachyon_session`, полученная через `POST /api/login`.
3. **Доверенный локальный доступ**: `localhost`, доверенные адреса локальной сети (LAN) или авторизованный пир в сети Tailscale (при включённом доступе).

> [!IMPORTANT]
> Поля учётных данных (`agent_api_token`, `clash_api_secret`, `server_subscription_token`, `new_password`) защищены от перезаписи через массовое сохранение настроек в обход специализированных процедур.

## Эндпоинты Agent REST API (`/api/agent/v1/*`)

Полная машиночитаемая спецификация доступна прямо с роутера:

- `GET /api/agent/v1/openapi.json` — схема OpenAPI для автогенерации клиентов и интеграций.

### Основные эндпоинты

| Метод и путь | Назначение |
|---|---|
| `GET /api/agent/v1/health` | Краткий статус доступности сервиса и ядра |
| `GET /api/agent/v1/snapshot` | Срез текущего состояния роутера и служб |
| `GET /api/agent/v1/config` | Текущая конфигурация с маскированием секретных полей (`[REDACTED]`) |
| `POST /api/agent/v1/config/plan` | План валидации конфигурации и выявление конфликтов (аналог `GET /api/diagnostics/config-plan`) |
| `POST /api/agent/v1/config/set` | Применение изменений параметров настроек |
| `GET /api/agent/v1/diagnose` | Полный диагностический отчёт (`Doctor`) |
| `POST /api/agent/v1/ai-doctor` | Запуск анализа AI Doctor |
| `POST /api/agent/v1/ai-doctor/fix` / `/heal` | Применение автоматического исправления по диагностике |
| `GET /api/agent/v1/route/explain` | Трассировка маршрута по целевому домену, порту, протоколу и IP клиента |
| `POST /api/agent/v1/domain/add` | Быстрое добавление домена (`domain`) в выбранную секцию (`section_id`) |
| `POST /api/agent/v1/section/toggle` | Включение или выключение секции маршрутизации |
| `POST /api/agent/v1/reload` / `/restart` | Пересборка конфигурации и перезапуск/reload `tachyon-core` |
| `GET /api/agent/v1/logs` | Последние структурированные логи сервиса и ядра |
| `GET /api/agent/v1/support-bundle` | Формирование отладочного пакета `support_bundle` |
| `GET /api/agent/v1/known-good` | Состояние последнего рабочего снимка конфигурации (`LKG`) |
| `GET /api/agent/v1/docs/search` | Поиск по встроенной базе знаний роутера |

Также доступны системные маршруты веб-приложения (`/api/telemetry`, `/api/bootstrap`, `/api/core/connections`, `/api/dns/block-stats` и др.).

### Пример `curl`-запросов

Проверка состояния и трассировка маршрута:

```sh
curl -fsS -H "Authorization: Bearer YOUR_AGENT_TOKEN" \
  http://192.168.1.1:1680/api/agent/v1/health

curl -fsS -H "Authorization: Bearer YOUR_AGENT_TOKEN" \
  "http://192.168.1.1:1680/api/agent/v1/route/explain?target=example.com&client_ip=192.168.1.10"
```

## Встроенный MCP-сервер (`src/mcp.rs`)

Tachyon 2.0 поддерживает два транспорта протокола **Model Context Protocol (JSON-RPC 2.0)**:

1. **HTTP**: `POST http://<router>:1680/mcp` или `POST http://<router>:1680/api/agent/v1/mcp` (с заголовком `Authorization: Bearer <token>`).
2. **Stdio (через SSH или локально)**: `tachyon mcp`.

### Полный перечень всех 11 MCP-инструментов

| Инструмент | Аргументы (`inputSchema`) | Назначение |
|---|---|---|
| `get_status` | `{}` | Возвращает обезличенный статус системы, ядра `tachyon-core` и отчёт Doctor |
| `route_explain` | `target` (*обязателен*), `client_ip`, `port`, `protocol` | Моделирует выбор маршрута через активные секции и условия |
| `config_plan` | `{}` | Валидирует текущую конфигурацию и проверяет коллизии правил |
| `apply_quick_fix` | `fix_id` (*обязателен*), `dry_run`, `force` | Применяет автоисправление (или предпросмотр `dry_run`) с верификацией «до и после» |
| `get_core_health` | `{}` | Живая телеметрия `tachyon-core`: память, файловые дескрипторы, UDP NAT, пул FakeIP, DNS-серверы и ошибки `DialErrorClass` по каждому выходу |
| `get_anomalies` | `{}` | Возвращает домены с повторяющимися ошибками соединения за последние 5 минут |
| `get_flight_failures` | `outbound`, `limit` | Последние неудачные или нулевые сессии из Flight Recorder с полями `error_kind` и `dial_ms` |
| `get_core_logs` | `level`, `limit` | Свежие структурированные логи `tachyon-core`, отфильтрованные по уровню важности |
| `capture_blackbox` | `reason` | Снимает анонимизированный диагностический снимок Blackbox в `tmpfs` (без записи во flash) |
| `flush_dns` | `scope` (`cache`, `upstream`, `all`) | Очищает кэш DNS-ответов и/или кэш адресов upstream-резолверов |
| `reset_outbound` | `tag` (*обязателен*), `close_sessions`, `stalled_only_ms` | Перезапускает/перепривязывает исходящий узел (например, WireGuard rebind / Urltest probe) и при необходимости сбрасывает зависшие потоки |

### Примеры подключения MCP-клиента

**Через HTTP (`POST /mcp`):**

```json
{
  "mcpServers": {
    "tachyon-router": {
      "url": "http://192.168.1.1:1680/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_AGENT_TOKEN"
      }
    }
  }
}
```

**Через SSH `stdio`:**

```json
{
  "mcpServers": {
    "tachyon-router-ssh": {
      "command": "ssh",
      "args": ["root@192.168.1.1", "tachyon", "mcp"]
    }
  }
}
```

---

[Предыдущая: Справочник CLI и конфигурации](13-cli-and-config.md) | [К оглавлению](README.md)
