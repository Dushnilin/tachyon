# Дизайн-спецификация: Универсальный слой Entware + Keenetic / Netcraze + USB в `tachyon` (ветка `2.0`)

## Цель и мотивация
Обеспечить установку и полноценную работу `Tachyon 2.0` (`G:\tachyon-rs`) из единого репозитория как на **OpenWrt**, так и на роутерах с **Entware** (включая **Keenetic / Netcraze** с прошивками NDMS 3.x–5.x, Asuswrt-Merlin, Padavan и Linux-шлюзах), в том числе при размещении Entware на внешнем **USB-накопителе**.

## Ключевые ограничения
1. **Единый репозиторий и сборка:** общий код Rust (`src/`), фронтенд (`fe-app-tachyon/`), единый `install.sh` / `uninstall.sh` и релизы в `Dushnilin/tachyon` (ветка `2.0`). Без новых зависимостей в `Cargo.toml` (Pure-Rust).
2. **Нулевой регресс на OpenWrt:** на OpenWrt сохраняются текущие пути (`/`), `NftablesDriver`, `fw4` guard, `procd`, `dnsmasq`/`odhcpd` и интеграция с LuCI.
3. **Совместимость с Linux 4.9+ и MIPS32:** никаких `AtomicU64`/`AtomicI64` вне `PortableAtomicU64` (`src/store.rs`), учёт `RUST_MIN_STACK=524288`.
4. **Защита от износа флеш-памяти и сбоев питания USB (Zero Flash Wear):**
   - Горячие/временные данные (`cache.db`, `.ephemeral`, `.volatile`, PID/lock-файлы, логи, кэш релизов) принудительно размещаются в **RAM `tmpfs`** (`/var/run/tachyon` или `/tmp/tachyon-rs`, проверенном по `/proc/mounts`), никогда на `/opt/tmp` или `/opt/var` USB-флешки.
   - Запись конфигов в `/opt/etc/tachyon/` выполняется через `write_file_if_changed_durable` (`temp -> sync_all -> rename -> fsync(dir)`).
   - В `install.sh` обязателен префлайт ФС (`ext2/ext3/ext4/f2fs/btrfs/xfs/ubifs`, отказ на `vfat/fat/exfat/ntfs` и `noexec`).
5. **Нейтральная терминология:** строго инженерно-сетевая лексика во всех текстах, коде, UI и комментариях.

## Архитектурные компоненты
1. **Платформенный слой (`src/platform.rs`):**
   - `PlatformKind`: `OpenWrt`, `KeeneticEntware`, `MerlinEntware`, `PadavanEntware`, `GenericEntware`.
   - `FirewallKind`: `Nftables`, `Iptables`.
   - `StorageInfo` (`InternalFlash`, `UsbExternal`, `TmpfsOnly`, `Unknown`) и `PlatformPaths` (`root` = `/` или `/opt`, с поддержкой `TACHYON_ROOT`).
   - `detect_default_lan_iface()` (`br-lan` vs `br0`), `has_managed_dnsmasq()`, `write_file_if_changed_durable()`.
2. **Адаптер Keenetic RCI (`src/platform_keenetic.rs`):**
   - Чистый Tokio HTTP/1.1 клиент к `127.0.0.1:79/rci/` (`show/version`, `show/ip/hotspot`, `show/interface`) с таймаутом 1500 мс и фоллбэком на `/proc/net/arp`, `ip neigh`.
3. **Драйвер `IptablesDriver` + `ipset` (`src/net_stack_iptables.rs`):**
   - `probe_entware_net_caps()` + выбор системного `iptables`/`ip6tables`.
   - Выделенные цепочки `TACHYON_DIVERT`, `TACHYON_PREROUTING`, `TACHYON_OUTPUT`, `TACHYON_DNS_NAT`, `TACHYON_INPUT`, `TACHYON_FORWARD`, `TACHYON_KILLSWITCH`.
   - Атомарные наборы `ipset restore -!` (`create _tmp / add / swap / destroy`) без OOM.
   - Полноценный **TProxy** (порт `1602`, fwmark `0x04000000` / `0x10000000`, table `100`) и **TUN** (как выбор или автофоллбэк без `xt_TPROXY`).
   - DNS-режим по умолчанию `redirect` (`dns-in` на `0.0.0.0:1053` + `REDIRECT` из LAN без поломки штатного `ndnproxy`) и опциональный `override` (`:53`).
4. **Защита Split-DNS (PR #496):**
   - Направление `local_domain_suffixes` и `static_hosts` в `dnsmasq-server` (`127.0.0.1:53`) включается строго при `!dont_touch_dhcp && has_managed_dnsmasq(dont_touch_dhcp)`.
5. **Init и хуки ОС (`entware/`):**
   - `/opt/etc/init.d/S99tachyon`
   - Keenetic NDM: `netfilter.d/100-tachyon.sh` (`reconcile-net`), `ifstatechanged.d/100-tachyon.sh` (`reload`), `fs.d/100-tachyon.sh` (остановка и снятие правил при извлечении USB).
   - Asuswrt-Merlin: `firewall-start.snippet`.
   - Самовосстановление цепочек в `watchdog.rs` для остальных Entware-систем.
6. **Упаковка, инсталлятор и самообновление:**
   - `tools/build_entware_pkg.py` собирает `tachyon-entware-<arch>-v<ver>.tar.gz` из тех же артефактов сборки `build.sh` и `.github/workflows/build.yml`.
   - Единый `install.sh` / `uninstall.sh` (`--platform auto|openwrt|entware`, `--root DIR`) и `updater.rs`.
7. **Синхронизированные доработки UI/API (PR #496–#498, Issue #494, #499):**
   - Пометка `(Рекомендуется)` и пояснение для `russia_inside` в Smart Detect (#494).
   - Индикатор страны фактического выхода (`GET /api/exit-country`, RPC `get_exit_country`, виджет дашборда) (#499).
   - Индикатор среды Entware/USB и настройки `entware_dns_mode` / `entware_dns_port` в UI.
