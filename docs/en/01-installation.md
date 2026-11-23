# Installation and 1.x Migration

[Русский](../ru/01-installation.md) | [Back to Index](README.md)

## System Requirements

- **Operating System**: OpenWrt `23.05+` or `24.10+` (`opkg` or `apk` package manager).
- **Supported Architectures**: `x86_64`, `i386_pentium4`, `aarch64`, `armv7`, `armv6`, `riscv64`, `mipsel`, `mips`.
- **Kernel Modules**: `kmod-nft-tproxy` (default TProxy mode), `kmod-tun` (when using TUN mode), `nftables` (`fw4`).
- **Memory & Storage**:
  - RAM: at least 256 MB recommended for basic setups; 512 MB+ for large rule sets and multiple subscriptions.
  - Flash: at least 25–40 MB free overlay space (or external storage for caches).
- **Transfer Utility**: `curl` or `wget` for the installer script.

> [!NOTE]
> `tachyon-core` is the sole routing engine in version 2.0. Legacy external engines (`sing-box`, `zapret`, `byedpi`) are not used in 2.0 and are removed on upgrade.

## Quick Installation via `install.sh`

Run the installer as `root` over SSH:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Dushnilin/tachyon/2.0/install.sh)" -- -y
```

To track pre-release builds (`beta` / `rc`), pass the channel flag:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Dushnilin/tachyon/2.0/install.sh)" -- -y --channel beta
```

### Complete `install.sh` Flag Reference

| Flag | Default | Description |
|---|---|---|
| `-y`, `--yes` | off | Run non-interactively without confirmation prompts |
| `-n`, `--dry-run` | off | Resolve target release and print the installation plan without modifying the router |
| `-q`, `--quiet` | off | Suppress informational messages |
| `--channel <CH>` | `auto` | Release channel: `auto`, `stable`, or `beta` (includes `rc`) |
| `--prerelease` | off | Include `beta` and `rc` pre-releases (alias for `--channel beta`) |
| `--tag <VERSION>` | — | Install an exact GitHub release tag, e.g. `--tag v2.0.0-rc.1` or `--tag v2.0.0` |
| `--format <FMT>` | `auto` | Package format override: `auto`, `apk`, or `ipk` |
| `--arch <ARCH>` | auto-detect | Override target architecture (`x86_64`, `aarch64`, `armv7`, `mipsel`, etc.) |
| `--reinstall` | off | Force package reinstallation over existing files |
| `--repair` | off | Repair init scripts, services, and package files in place |
| `--tachyon-core` | compatibility | Compatibility flag (`tachyon-core` is always the built-in engine) |
| `--repo <OWNER/REPO>` | `Dushnilin/tachyon` | Override release source repository |
| `--skip-core` | off | Skip downloading or updating the `tachyon-core` binary |
| `-h`, `--help` | — | Display command usage help |

Installation logs are written to `/tmp/tachyon-install.log`.

## Migrating from Tachyon 1.x to 2.0

When installing 2.0 on top of Tachyon 1.x, the installer and service automatically import legacy UCI settings (`/etc/config/tachyon`) into `/etc/tachyon/tachyon.json`:

1. A backup of `/etc/config/tachyon` is preserved before applying changes.
2. Routing sections, traffic conditions, outbound pools, balancers, family profiles, schedules, guest mode settings, inbound servers, and Telegram bot configuration are migrated.
3. Built-in rule references are switched from legacy `.srs` paths to native `.trs` where applicable; custom user-supplied `.srs` URLs continue to work as compatibility fallbacks.

You can trigger or re-run legacy import manually at any time:

```sh
tachyon import-legacy
```

Verify the migrated plan and service status afterward:

```sh
tachyon config_plan
tachyon status
```

## Release Policy and Channels

Tachyon follows a staged release cycle across components:

1. **`beta`** — initial feature testing and early feedback.
2. **`rc` (Release Candidate)** — feature freeze and stability verification prior to general availability.
3. **`stable`** — general production release promoted from verified pre-releases.

See [Updates, Channels, and System Settings](11-updates-settings.md) for configuring update channels (`auto`, `stable`, `beta` including `rc`) in the Web UI.

## Uninstalling

To remove Tachyon while preserving a configuration backup under `/etc/tachyon-backup-<timestamp>`:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Dushnilin/tachyon/2.0/uninstall.sh)" -- -y
```

Additional `uninstall.sh` options:

- `-p`, `--purge` — remove all configurations, state files, and backups without saving a backup copy.
- `--keep-binaries` — keep `/usr/bin/tachyon-core` installed on disk.

---

[Back to Index](README.md) | [Next: Quick Start](02-quickstart.md)
