# Podkop Plus

[![Star](https://img.shields.io/github/stars/ushan0v/podkop-plus?style=social)](https://github.com/ushan0v/podkop-plus/stargazers)
[![Releases](https://img.shields.io/github/v/release/ushan0v/podkop-plus?label=releases)](https://github.com/ushan0v/podkop-plus/releases)
[![Original](https://img.shields.io/badge/original-itdoginfo%2Fpodkop-blue)](https://github.com/itdoginfo/podkop)
[![podkop-evolution](https://img.shields.io/badge/podkop--evolution-yandexru45-blue)](https://github.com/yandexru45/podkop-evolution)
[![zapret-openwrt](https://img.shields.io/badge/zapret--openwrt-remittor-blue)](https://github.com/remittor/zapret-openwrt/releases)

Podkop Plus расширяет возможности оригинального [Podkop](https://github.com/itdoginfo/podkop): обновленный LuCI-интерфейс, гибкое управление секциями, поддержка подписок, расширенные условия правил, интеграция Zapret.

<table>
  <tr>
    <td>
      <img height="320" alt="preview_sections" src="https://github.com/user-attachments/assets/006e737b-e755-4c3c-939d-ca1a828cf11a" />
    </td>
    <td>
      <img height="320" alt="preview_dashboard" src="https://github.com/user-attachments/assets/0bbab5b0-cc7f-4841-b459-9d6e0e263e18" />
    </td>
  </tr>
</table>

### Установка

```sh
sh <(wget -O - https://raw.githubusercontent.com/ushan0v/podkop-plus/main/install.sh)
```

### Возможности

- Поддержка подписок, адаптированная из [podkop-evolution](https://github.com/yandexru45/podkop-evolution). Расширена поддержка всех основных форматов подписок: sing-box JSON, URI/base64 списки, Clash/Mihomo. Добавлено чтение метаданных подписки.
- Обновленный LuCI-интерфейс секций. Расширенное управление секциями: изменение приоритета, новые условия и значения.
- Интеграция Zapret как отдельного действия для секции (опционально).

### Секции

Podkop Plus расширяет набор условий, которые можно использовать в правилах:

- Домены (`domain_suffix`)
- IP-адреса (`ip_cidr`)
- Точный полный домен (`domain`)
- Ключевое слово домена (`domain_keyword`)
- Регулярное выражение домена (`domain_regex`)
- Исходные IP-адреса (`source_cidr`)
- Встроенные наборы правил
- Наборы правил (домены)
- Наборы правил (домены и подсети)
- Списки доменов и IPs

### Наборы правил

`Наборы правил (домены)` принимают sing-box списки в форматах `.srs` и `.json`. Можно указывать как локальные пути, так и удаленные ссылки. Такие списки добавляются только в конфигурацию sing-box.

`Наборы правил (домены и подсети)` принимают те же форматы, но дополнительно извлекают подсети и добавляют их в nftables. Это полезно для списков, где важны не только домены, но и IP-диапазоны. Извлечение подсетей требует дополнительной нагрузки на роутер, поэтому секции разделены.

### Списки доменов и IPs

Секция `Списки доменов и IPs` объединяет списки доменов и подсетей. Принимает локальные и удаленные `.lst` списки. Добавлена поддержка смешанных списков.

### Интеграция Zapret

Zapret доступен как действие отдельной секции. Используется [remittor/zapret-openwrt](https://github.com/remittor/zapret-openwrt/releases). Интеграция не конфликтует с отдельным полноценным пакетом zapret (`luci-app-zapret`).

- `sing-box` отбирает и помечает трафик;
- `zapret` принимает этот трафик и применяет выбранную anti-DPI стратегию.

Для Zapret стратегии NFQWS намеренно ограничены. Это нужно, чтобы Podkop Plus сам помечал трафик и управлял очередями, fwmark и жизненным циклом процесса.

Запрещены:

- шаблоны и hostlist placeholders: **`<HOSTLIST>`**, **`<HOSTLIST_NOAUTO>`**;
- hostname/IP selectors внутри самой стратегии: **`--hostlist*`**, **`--hostlist-auto*`**, **`--ipset*`**;
- ручное управление очередью и fwmark: **`--qnum`**, **`--dpi-desync-fwmark`**;
- режимы, которые ломают lifecycle процесса: **`--daemon`**;
- режимы, которые не должны быть итоговой стратегией запуска: **`--dry-run`**, **`--version`**;
- внешние конфиги вида **`@file`** или **`$file`**, которые обходят встроенную валидацию и управление очередями.
