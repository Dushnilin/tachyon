# 07. Build System, Testing & Deployment Pipeline

## 1. Release Package Compilation (`build.sh`)

Tachyon produces both legacy **IPK** (opkg) and modern **APK** (apk-tools, OpenWrt 25.x+) packages.

### 1.1. Running the Build

```bash
bash build.sh <x.y.z> [output-dir]
```

* **Semver Requirement**: `build.sh` strictly enforces semantic versioning (`x.y.z`).
* **Cross-Filesystem WSL Protection**: When executed under Windows Subsystem for Linux (WSL), `build.sh` automatically clones the source repository into the native Linux filesystem (`/tmp/tachyon-build-...`) before packaging to avoid Windows filesystem metadata and permission corruption.
* **Outputs**:
  * `dist/release-final/tachyon_<version>_all.ipk`
  * `dist/release-final/luci-app-tachyon_<version>_all.ipk`
  * `dist/release-final/tachyon-<version>.apk`
  * `dist/release-final/luci-app-tachyon-<version>.apk`

---

## 2. End-User Installer (`install.sh`)

Tachyon provides an automated one-liner installer:

```bash
sh <(wget -O - https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh)
```

### 2.1. Installer Lifecycle
1. **Architecture & OS Detection**: Detects OpenWrt version (23.05, 24.10, 25.x, SNAPSHOT), CPU architecture (`mips`, `mipsel`, `arm_cortex-a7`, `aarch64_cortex-a53`, `x86_64`), and package manager (`opkg` vs `apk`).
2. **Dependency Resolution**: Ensures `ucode`, `ucode-mod-fs`, `ucode-mod-uci`, `ucode-mod-ubus`, `kmod-nft-tproxy`, `kmod-nft-queue`, `ca-bundle` are installed.
3. **Legacy Migration**: Automatically detects `/etc/config/forkop` or `/etc/config/podkop` and seamlessly migrates all rules and servers to `/etc/config/tachyon`.
4. **Binary Provisioning**: Downloads pre-compiled, optimized sing-box, Zapret, or ByeDPI binaries tailored for the router's target architecture.
5. **Zero-Reboot Initialization**: Configures UCI defaults, registers LuCI menus, builds initial rulesets, and starts services without requiring a full router reboot.

---

## 3. Testing Workflows

### 3.1. Frontend Unit Tests (vitest)

```bash
cd fe-app-tachyon
npm test           # Runs all 522+ vitest unit tests
npm run build      # Verifies TypeScript compilation and LuCI bundle packaging
```

### 3.2. Backend Integration Tests & ucode Syntax Linting

Backend tests require the `ucode` binary. On development machines without local ucode, tests run inside the Docker CI image:

```bash
# 1. ucode syntax check across all 60+ modules
docker run --rm -v "$(pwd):/mnt" -w /mnt ucode-ci-img:latest bash tests/ucode_syntax_lint.sh

# 2. Run all backend behavioral and unit tests in parallel (-P4)
docker run --rm -v "$(pwd):/mnt" -w /mnt ucode-ci-img:latest bash tests/run_all.sh

# 3. Run a specific test
docker run --rm -v "$(pwd):/mnt" -w /mnt ucode-ci-img:latest bash tests/ai_doctor_local.sh
```

### 3.3. ShellCheck Linting

```bash
shellcheck --severity=error build.sh install.sh tachyon/files/etc/init.d/* tests/**/*.sh
```

---

## 4. Key Developer Gotchas & Conventions

1. **LF Line Endings**: Enforced via `.gitattributes`. Committing CRLF will break shell scripts on OpenWrt target systems.
2. **`fe-app-tachyon` Package Manager**: Always use `npm` (`npm install`, `npm test`, `npm run build`), not `yarn`.
3. **Version Placeholder**: `__COMPILED_VERSION_VARIABLE__` in `src/constants.ts` is replaced during `build.sh` packaging. Do not remove it.
4. **UCI Config Permissions**: `/etc/config/tachyon` must remain `chmod 600` because it can store sensitive Telegram bot tokens and API keys.
