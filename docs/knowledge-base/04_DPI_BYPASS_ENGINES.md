# 04. Движки обхода DPI и десинхронизации пакетов

Tachyon интегрирует три независимых локальных движка десинхронизации сетевых пакетов, которые функционируют непосредственно на оборудовании роутера без необходимости использования внешнего VPS или прокси-сервера (режим «Zero-VPS»).

---

## 1. Сравнительная матрица: Zapret v1 vs Zapret v2 vs ByeDPI

| Параметр | Zapret v1 (`nfqws`) | Zapret v2 (`nfqws2`) | ByeDPI (`ciadpi`) |
|---|---|---|---|
| **Исполняемый файл** | `/usr/bin/nfqws` | `/usr/bin/nfqws2` | `/usr/bin/ciadpi` |
| **Модель работы** | Перехват через Kernel NFQueue | Multi-Queue NFQueue с Lua | Локальный SOCKS5 / TProxy |
| **Целевые протоколы** | HTTP, TLS (ClientHello) | HTTP, TLS, QUIC, WireGuard, UDP | HTTP, TLS |
| **Методы фрагментации** | `split2`, `disorder`, `fake` | `multisplit`, `seqovl`, `wsize`, `fake` | `--split-pos`, `--disorder`, `--fake` |
| **Многоуровневые цепочки** | 1 стратегия на правило | Сложные составные цепочки | Составные аргументы SOCKS |
| **Нагрузка на CPU** | Минимальная (< 1%) | Низкая (< 2%) | Низкая (< 2%) |
| **Оптимально для** | Базового DPI, старых роутеров | YouTube 4K, Discord, ТСПУ | Не-root окружений, SOCKS-роутинга |

---

## 2. Принципы и техники десинхронизации пакетов

Системы глубокого анализа пакетов (DPI / ТСПУ) анализируют заголовки сетевых протоколов (такие как `SNI` в расширении TLS ClientHello или заголовок `Host` в HTTP) для блокировки или замедления трафика. 

Десинхронизация обманывает конечный автомат DPI, заставляя его потерять контекст TCP-сессии или пропустить целевой заголовок, в то время как целевой сервер корректно собирает исходный поток данных.

```
Исходный поток:   [TLS ClientHello с SNI] ──────────► (Блокируется ТСПУ / DPI)

Десинхронизация:  [Fake-пакет с неверной суммой/TTL] ──► (DPI сбрасывает состояние)
                  [Фрагмент 1: Начало ClientHello]  ───► (DPI не видит полный SNI)
                  [Фрагмент 2: Окончание данных]  ─────► (Сервер собирает TCP-поток)
```

### 2.1. Основные стратегии обхода

1. **`split2` / `multisplit` (Многопозиционное разделение)**:
   * Разрезает TCP-сегмент непосредственно внутри поля TLS SNI или заголовка HTTP Host. Оборудование DPI не выполняет глубокую реассемблинг-сборку мелких фрагментов, а стек TCP целевого сервера склеивает поток без потерь.
2. **`disorder` / `disorder2` (Изменение порядка доставки)**:
   * Отправляет вторую часть пакета раньше первой с корректными TCP Sequence Numbers. DPI видит фрагменты не по порядку и пропускает инспекцию.
3. **`fake` / `fake_sni` (Внедрение фейковых пакетов)**:
   * Отправляет поддельный пакет TLS ClientHello с намеренно заниженным TTL (Time To Live). DPI перехватывает поддельный пакет и считает соединение легитимным, после чего пакет угасает в сети, не доходя до целевого сервера.
4. **`seqovl` (Наложение порядковых номеров / Sequence Overlap)**:
   * Посылает пакет с перекрывающимся диапазоном TCP Sequence. Стек TCP на сервере отбрасывает дублирующиеся байты, тогда как DPI парсит неверные данные и теряет контроль над сессией.
5. **`wsize` (Манипуляция размером окна TCP Window Size)**:
   * Принудительно устанавливает размер TCP-окна в 1–2 байта, заставляя клиент слать данные микросегментами, что ломает эвристики DPI.

---

## 3. Конфигурация и управление в UCI

### 3.1. Пример настройки Zapret v2 (`/etc/config/tachyon`)

```ini
config provider 'zapret2'
    option enabled '1'
    option daemon_bin '/usr/bin/nfqws2'
    option qnum '201'
    option args_tcp '--dpi-desync=multisplit --dpi-desync-split-pos=1,midsld --dpi-desync-seqovl=1 --dpi-desync-fooling=badseq'
    option args_udp '--dpi-desync=fake --dpi-desync-any-protocol=1 --dpi-desync-cutoff=d4'

config rule 'youtube_rule'
    option enabled '1'
    option name 'YouTube 4K Desync'
    option action 'zapret2'
    list domain_pattern 'googlevideo.com'
    list domain_pattern 'youtube.com'
    list domain_pattern 'ytimg.com'
    list domain_pattern 'discord.gg'
    list domain_pattern 'discord.com'
```

### 3.2. Пример настройки ByeDPI

```ini
config provider 'byedpi'
    option enabled '1'
    option daemon_bin '/usr/bin/ciadpi'
    option listen_ip '127.0.0.1'
    option listen_port '1080'
    option args '--split-pos 1 --disorder 1 --fake -1 --ttl 8'
```

---

## 4. Мультиплексирование NFQueue и изоляция очередей

* Подсистема ядра Linux `nfnetlink_queue` требует уникальный номер очереди (`qnum`) для каждого запущенного процесса демона.
* Модуль `providers/nfqueue/runtime.uc` в Tachyon динамически управляет выделением очередей:
  * Базовая очередь Zapret v1: `200`
  * Базовая очередь Zapret v2: `201`
  * Очередь Strategy Fuzzer: `298` / `299`
* При одновременной активации Zapret v1 и Zapret v2 для разных правил маршрутизации Tachyon гарантирует строгую изоляцию очередей и исключает конфликты PID и fwmark.

---

## 5. Интеграция AmneziaWG в sing-box-extended (2026)

Проверено против релизного бинарника `v1.13.18-extended-2.6.5` (`shtorm-7/sing-box-extended`):

- Секция `endpoint.amnezia` полностью реализована в форке: `AmneziaOptions` (`transport/wireguard/endpoint_options.go`) → параметры IPC `jc / jmin / jmax / s1-s4 / h1-h4 / i1-i5`.
- Форк `shtorm-7/wireguard-go v0.0.4-extended-1.5.3`: пакеты `I1–I5` отправляются отдельными дейтаграммами **перед** инициализацией рукопожатия (`SendHandshakeInitiation`), значение задается в hex-формате.
- Генератор Tachyon (`singbox/generator_outbounds.uc` -> `add_awg_endpoint`) формирует конфигурацию, полностью совместимую со схемой форка:
  - Секция `peer` содержит обязательный `allowed_ips`.
  - Параметры `pre_shared_key` и `persistent_keepalive_interval` опциональны.
  - Hex-значения `i1–i5` передаются через `uci_bin_to_hex` без повторного кодирования.
- **Диагностика:** если AWG/WARP-туннель имеет состояние «TX есть, RX нет» на sing-box-extended, конфиг применен корректно — причина во внешней UDP-фильтрации провайдера или блокировке сервера.

---

## 6. Strategy Fuzzer и автоматический подбор стратегий

Tachyon включает встроенный модуль автоматического тестирования стратегий обхода — **Strategy Fuzzer & Auto-Tuner** (`diagnostics/fuzzer.uc`), который избавляет от необходимости вручную подбирать флаги `nfqws2` или `ciadpi`.

### 6.1. Механизм работы
- **Изолированный сэндбокс:** Тестирование выполняется через временные очереди `qnum 298/299` с сокетной меткой `0x08000000` (для Zapret) либо через локальный порт `127.0.0.1:11089` (для ByeDPI), не затрагивая активный домашний трафик.
- **Метрический скоринг:** Замеряются время TLS-рукопожатия, TTFB (время до первого байта), битрейт загрузки чанка потокового видео (MB/s) и HTTP-код ответа.
- **1-Click Apply:** Победившая стратегия мгновенно применяется к правилу YouTube/Discord или в глобальные параметры провайдера с автоматической перезагрузкой службы.

### 6.2. Команды управления через CLI
```sh
# Запуск бенчмарка стратегий
tachyon fuzzer_start <engine> <target> [custom_url] [rule_section]

# Просмотр текущего прогресса и результатов
tachyon fuzzer_status

# Остановка фонового бенчмарка
tachyon fuzzer_stop

# Применение выбранной стратегии в UCI
tachyon fuzzer_apply <engine> "<strategy_args>" [target_rule_or_global]

# Вывод доступной матрицы стратегий
tachyon fuzzer_strategies
```
