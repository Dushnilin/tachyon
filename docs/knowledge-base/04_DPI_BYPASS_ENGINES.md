# 04. Движки пакетной десинхронизации и локальные провайдеры

Tachyon интегрирует несколько независимых движков десинхронизации сетевых пакетов и специализированных туннельных провайдеров, которые работают непосредственно на роутере OpenWrt (как в режиме «Zero-VPS» без внешнего сервера, так и в гибридном режиме совместно с `tachyon-core` / `sing-box`).

---

## 1. Сравнительная матрица движков десинхронизации

| Параметр | Zapret v2 (`nfqws2`) | Zapret v1 (`nfqws`) | ByeDPI (`ciadpi`) | Native `desync` (`tachyon-core`) |
|---|---|---|---|---|
| **Исполняемый файл** | `/opt/zapret2/nfq2/nfqws2` | `/opt/zapret/nfq/nfqws` | `/usr/bin/ciadpi` | Встроен в `/usr/bin/tachyon-core` |
| **Модель перехвата** | Kernel NFQueue `201+` + Lua | Kernel NFQueue `200+` | Локальный SOCKS5 (`127.0.0.1:4539`) | Нативный L4/L7 dialer внутри ядра |
| **Целевые протоколы** | HTTP, TLS, QUIC, STUN, Discord UDP, кастомный UDP | HTTP, TLS, QUIC | HTTP, TLS (TCP) | TLS, HTTP, QUIC/UDP |
| **Синтаксис флагов** | `--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq` | `--dpi-desync=fake,split2 --dpi-desync-split-pos=1,midsld` | `-s 1 -d 1 --auto=t,r,s -o 1` | `mode=fake_split split_pos=midsld fake_ttl=4 repeats=6` |
| **Многоуровневые профили** | Мультипрофили через `--new` в одном процессе | 1 профиль или `--new` | Составные группы `--auto` | На уровне секции / outbound |

> [!IMPORTANT]
> **Никогда не путайте синтаксис Zapret v1 и Zapret v2:**
> - **Zapret v2 (`nfqws2`)** принимает ТОЛЬКО флаги `--lua-desync=<функция>[:ключ=значение...]` (используя предзагруженные Lua-библиотеки `/opt/zapret2/lua/zapret-lib.lua`, `zapret-antidpi.lua`, `zapret-auto.lua`). Флаги `--dpi-desync` от первой версии в `nfqws2` не существуют.
> - **Zapret v1 (`nfqws`)** принимает классические флаги `--dpi-desync=...`, `--dpi-desync-split-pos=...`, `--dpi-desync-fooling=...`.

---

## 2. Принципы и техники десинхронизации пакетов

Промежуточные сетевые фильтры (middlebox / DPI) анализируют заголовки начальных пакетов соединения (расширение `SNI` в TLS ClientHello, заголовок `Host` в HTTP, начальные датаграммы QUIC/UDP).

Десинхронизация модифицирует структуру исходящих пакетов так, чтобы транзитный фильтр потерял контекст сессии, а целевой сервер корректно собрал поток по стандартам TCP/IP:

1. **`multisplit` / `split2` (Многопозиционная фрагментация)**:
   * Разрезает TCP-сегмент внутри поля TLS SNI (`pos=1,midsld,sniext+4`). Транзитный узел не видит цельной сигнатуры домена, а стек TCP сервера склеивает сегменты без потерь.
2. **`multidisorder` / `disorder2` (Обратный порядок сегментов)**:
   * Отправляет второй фрагмент раньше первого с валидными TCP Sequence Numbers.
3. **`fake` (Инжекция ложных пакетов)**:
   * Отправляет перед реальным ClientHello фейковый пакет с ограниченным временем жизни (`ttl` / `ip_ttl`) или модифицированной подписью (`fooling=badseq`, `fooling=md5sig`, `tcp_ts=-600000`). Фейковый пакет сбрасывает автомат фильтра на маршруте, но отбрасывается целевым сервером.
4. **`seqovl` (Наложение TCP Sequence Numbers)**:
   * Второй фрагмент имеет сдвиг Sequence назад (`seqovl=1`), перекрывая конец первого сегмента.
5. **`wsize` (Ограничение TCP Window Size)**:
   * Занижает размер окна TCP (`wsize=1`), принуждая разбивать ответный и исходящий поток на микросегменты.

---

## 3. Настройка в модульной схеме UCI (`/etc/config/tachyon`)

В актуальной архитектуре Tachyon правила десинхронизации связываются через модульные секции `section` + `condition` + `outbound_source` (либо поля стратегии прямо в `section`):

```ini
config condition 'cond_media'
    option enabled '1'
    option name 'YouTube & Discord Domains'
    option condition_type 'atomic'
    list community_lists 'youtube'
    list community_lists 'discord'
    list user_domains 'googlevideo.com'
    list user_domains 'youtube.com'

config outbound_source 'src_zapret2_media'
    option enabled '1'
    option name 'Zapret2 Multisplit'
    option source_type 'provider'
    option provider_kind 'zapret2'
    option nfqws2_strategy '--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq'

config section 'sec_media'
    option enabled '1'
    option label 'Media Packet Optimization'
    option connection_type 'zapret2'
    option action 'zapret2'
    list condition_refs 'cond_media'
    list outbound_source_refs 'src_zapret2_media'
```

---

## 4. Мультиплексирование NFQueue и специализированные провайдеры

### 4.1. Изоляция очередей NFQueue (`providers/nfqueue/runtime.uc`)
* Базовая очередь Zapret v1 (`nfqws`): `200+`
* Базовая очередь Zapret v2 (`nfqws2`): `201+`
* Очереди изолированного сэндбокса Strategy Fuzzer: `298` / `299` (с сокет-меткой `0x08000000`)
* Пакеты после обработки демоном маркируются `0x40000000` (`NFT_COMMON_MARK`), что исключает повторное попадание в очередь.

### 4.2. Дополнительные провайдеры (`providers/`)
* **`wdtt` (`providers/wdtt/`)**: специализированный туннель для WebRTC, голосовых каналов Discord и звонков Telegram.
* **`olcrtc` (`providers/olcrtc/`)**: ретранслятор медиа- и RTC-трафика.
* **`fptn` (`providers/fptn/`)**: клиент устойчивого к фильтрации VPN-протокола FPTN.
* **`tailscale` (`providers/tailscale/`)**: интеграция mesh-сети Tailscale (нативный демон `tailscaled` или встроенный endpoint в `sing-box`).
* **`torrserver` (`torrserver/direct.uc`)**: автоматический прямой обход для локального медиа-сервера TorrServer.

---

## 5. Интеграция AmneziaWG в `sing-box-extended` / `tachyon-core`

- Секция `endpoint.amnezia` поддерживает параметры обфускации рукопожатия WireGuard: `jc`, `jmin`, `jmax`, `s1–s4`, `h1–h4`, `i1–i5`.
- Пакеты сигнатурной маскировки `I1–I5` отправляются отдельными UDP-дейтаграммами перед `SendHandshakeInitiation`.
- Генератор Tachyon (`tachyon_core/generator_outbounds.uc` -> `add_awg_endpoint`) автоматически компилирует эти поля из UCI или конфигов Amnezia.
- Если выбран стандартный бинарник `sing-box` без поддержки `amnezia`, `diagnostics/doctor.uc` обнаружит это и предложит быстрое исправление `upgrade_to_singbox_extended`.

---

## 6. Strategy Fuzzer и ИИ-генератор стратегий (`diagnostics/fuzzer.uc`, `diagnostics/fuzzer/ai.uc`)

Встроенный бенчмарк стратегий тестирует комбинации флагов `zapret2`, `zapret`, `byedpi` и нативного `desync` в изолированном сэндбоксе без разрыва домашнего интернета:
- **Изоляция:** NFQueue `298/299` (fwmark `0x08000000`) или локальный порт `127.0.0.1:11089` для `ciadpi`.
- **Метрики:** время TLS-рукопожатия, TTFB, скорость скачивания потокового видеочанка и HTTP-статус.
- **AI Strategy Generator (`fuzzer/ai.uc`):** использует RAG (`diagnostics/rag.uc`) и подключённую LLM для генерации 3–5 валидных стратегий под конкретный сервис и сетевой профиль оператора, автоматически очищая все входные данные от любых секретов и нормализуя синтаксис через `sanitize_strategy_args()` + `validate_strategy_args()`.
