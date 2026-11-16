# 04. Нативная десинхронизация пакетов и встроенные транспорты (`tachyon-core`)

Tachyon выполняет локальную десинхронизацию пакетов и специализированное туннелирование непосредственно внутри нативного Rust-ядра **`tachyon-core`** (без внешних демонов NFQueue или локальных SOCKS-прокси), а также поддерживает выделенный L3-провайдер **FPTN** и встроенные в ядро транспорты **CSQTT/WDTT**, **Tailscale** и **AmneziaWG**.

---

## 1. Нативный Outbound `desync` (Adaptive 2.0) в `tachyon-core`

Встроенный outbound типа `desync` модифицирует параметры исходящих соединений на уровне L4/L7 внутри сетевого стека `tachyon-core` при взаимодействии с промежуточными сетевыми узлами (middlebox):

| Параметр | Значение / Диапазон | Назначение |
|---|---|---|
| `desync_preset` | `auto`, `tlsrec`, `custom`, и др. | Пресет профиля десинхронизации (`auto` включает Adaptive 2.0 с поддержкой TCP и UDP/QUIC) |
| `desync_mode` | `fake_split`, `fake_disorder`, `multi_split`, `multi_disorder`, `fake` | Режим фрагментации или инжекции ложных сегментов при `preset = "custom"` |
| `desync_split_pos` | число (`1`, `2`) или символ (`sni`, `midsld`, список `1,sni,midsld-2`) | Позиция разрезания TCP-потока / TLS ClientHello |
| `desync_fake_ttl` | целое число (`1..32`, обычно `4..8`) | Ограничение TTL ложных пакетов для остановки на транзитном узле |
| `desync_fake_sni` | доменное имя | Подставной SNI в ложном пакете |
| `desync_fooling` | `badsum`, `md5`, `autottl`, `badack`, `md5_badack` | Способ отклонения ложного пакета на целевом сервере |
| `desync_repeats` | целое число | Количество повторов ложных пакетов |
| `desync_auto_tune` | `0` / `1` | Автоматическая подстройка параметров в Adaptive 2.0 |

> [!NOTE]
> Устаревшие внешние секции `zapret`, `zapret2` и `byedpi` автоматически мигрируют в нативный `action = "desync"` с `desync_preset = "auto"` (Adaptive 2.0) при обновлении конфигурации в `config/migration.uc`.

---

## 2. Настройка в модульной схеме UCI (`/etc/config/tachyon`)

Правила десинхронизации связываются через модульные секции `section` + `condition` + `outbound_source` (либо задаются напрямую в `section`):

```ini
config condition 'cond_media'
    option enabled '1'
    option name 'Media Domains'
    option condition_type 'atomic'
    list community_lists 'youtube'
    list community_lists 'discord'
    list user_domains 'googlevideo.com'
    list user_domains 'youtube.com'

config outbound_source 'src_desync_auto'
    option enabled '1'
    option name 'Desync Adaptive 2.0'
    option source_type 'desync'
    option desync_preset 'auto'

config section 'sec_media'
    option enabled '1'
    option label 'Media Packet Optimization'
    option action 'connection'
    list condition_refs 'cond_media'
    list outbound_source_refs 'src_desync_auto'
```

---

## 3. Встроенные транспорты и провайдеры

### 3.1. Нативный WDTT / CSQTT (`tachyon-core`)
* Встроенный транспорт `wdtt` в `tachyon-core` поддерживает схемы `csqtt://`, `wdtt://` и `qwdtt://` (включая режимы `csqtt`, `wg`, `raw`, параметры TURN/VK, пулы и отказоустойчивость `priority_failover`).
* Работает напрямую как outbound и inbound ядра `tachyon-core` без внешнего демона `qwdtt-client`.

### 3.2. Нативный Tailscale (`tachyon-core`)
* Встроенный endpoint `type: "tailscale"` в `tachyon-core` (для исходящих и серверных секций) обеспечивает маршрутизацию в mesh-сеть (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `ts.net`) и работу MagicDNS без запуска отдельного демона `tailscaled`.

### 3.3. Выделенный провайдер FPTN (`providers/fptn/`) и TorrServer (`torrserver/direct.uc`)
* **`fptn` (`providers/fptn/`)**: клиент L3-туннелирования поверх WebSocket/TLS (`tun-fptn`, таблица `4249`), поддерживается как внешний клиент или через встроенный транспорт ядра.
* **`torrserver` (`torrserver/direct.uc`)**: автоматическое исключение локального медиа-сервера TorrServer из перехвата.

---

## 4. Интеграция AmneziaWG в `tachyon-core`

- Секция `endpoint` типа `wireguard` с параметрами AmneziaWG поддерживает поля: `jc`, `jmin`, `jmax`, `s1–s4`, `h1–h4`, `i1–i5`.
- Пакеты сигнатурной маскировки `I1–I5` отправляются отдельными UDP-дейтаграммами перед `SendHandshakeInitiation`.
- Генератор Tachyon (`tachyon_core/generator_outbounds.uc` -> `add_awg_endpoint`) автоматически компилирует эти поля из UCI или импортированных профилей `.conf`.

---

## 5. Strategy Fuzzer и ИИ-генератор стратегий (`diagnostics/fuzzer.uc`, `diagnostics/fuzzer/ai.uc`)

Встроенный бенчмарк стратегий тестирует пресеты и комбинации параметров нативного движка **`desync`** (`tachyon-core`) без прерывания основного трафика роутера:
- **Движок по умолчанию:** `desync` (`tachyon-core`).
- **База пресетов:** `tachyon/files/usr/share/tachyon/dpi-presets.json` (секция `"desync"`).
- **Метрики:** время TLS-рукопожатия, TTFB, скорость скачивания потокового видеочанка и HTTP-статус.
- **AI Strategy Generator (`fuzzer/ai.uc`):** использует RAG (`diagnostics/rag.uc`) и подключённую LLM для генерации валидных стратегий `desync` под конкретный сервис и профиль сети, предварительно очищая входные данные от секретов и нормализуя параметры через `sanitize_strategy_args()` + `validate_strategy_args()`.
