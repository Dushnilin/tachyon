# Troubleshooting and FAQ

[Русский](../ru/12-troubleshooting-faq.md) | [Back to Index](README.md)

## Quick Initial Triage

If traffic stops forwarding or fails after configuration changes, run these baseline checks:

1. Run local verification via CLI or `Analytics -> Diagnostics`:
   ```sh
   tachyon status
   tachyon config_plan
   ```
2. Trace a specific failing destination:
   ```sh
   tachyon explain example.com 192.168.1.10
   ```
3. Generate an anonymized diagnostic archive:
   ```sh
   tachyon support_bundle > /tmp/tachyon-support.json
   ```

## Common Issues and Resolutions

### 1. A Section Is Quarantined (`quarantined_sections`)

When compiling runtime configs, `tachyon-core` validates every outbound node and rule set. If one section contains an invalid URL or malformed parameter, it is quarantined (`/var/run/tachyon/section-errors.json`) so **all other healthy sections keep running uninterrupted**.
- Check the Dashboard or `Routing -> Routing Sections` for the warning badge explaining the exact failure.
- Correct the section's source or condition and click **Save & Apply**, or temporarily disable the broken section.

### 2. Subscriptions Fail to Fetch or Domains Do Not Resolve

- Verify router DNS reachability under `Settings -> DNS & Protection` via **`Test DNS speed`**.
- Ensure `Bootstrap DNS` contains reachable numeric IPs (such as `77.88.8.8`, `1.1.1.1`) so encrypted DoH/DoT hostnames resolve before tunnels come up.
- If a subscription endpoint is unreachable directly over WAN, enable `download_via_proxy_enabled` on that source and pick a working fallback section.
- Enable `auto_user_agent` under the source's advanced tab if the provider filters responses by client header.

### 3. IPv6 or WebRTC Leaks Detected

- Open `Settings -> Network & TUN` and verify **`IPv6 Leak Protection (Leak Guard)`** is enabled (`ipv6_leak_guard = true`), and IPv6 mode is set to `Auto` or `IPv4 Only`.
- Confirm **`Intercept all DNS queries`** (`dns_intercept_all`) is enabled so clients with hardcoded DNS or browser DoH do not skip FakeIP.
- Inspect the `Leak Guard & Flight Recorder` card in `Analytics -> Diagnostics`: `IPv4`, `IPv6`, `WebRTC STUN`, and `DNS Intercept` should all report protected states.

### 4. Core Fails to Start After Config Edits

If a recent edit broke startup or router access, roll back to the Last Known Good snapshot immediately:

```sh
tachyon rollback
```

Or run safe core recovery:

```sh
tachyon quick_fix restart_core
```

**Last Known Good (LKG)** snapshots are captured automatically and can also be restored from the top-bar Changes dialog or `/rollback` in Telegram.

### 5. Low RAM or Flash Space on 128–256 MB Routers

- Enable **`Eco Mode` (`lite_mode`)** in the top bar.
- Leave **`Pre-download all preset lists`** disabled under `Settings -> Lists & Presets` so only `.trs` rule sets referenced by active sections are fetched.
- Periodically free memory caches using **`Trim RAM Caches`** in `Diagnostics` or `/trim_ram` in Telegram.
- Keep **`flash_wear_protection`** enabled so telemetry and logs remain in `/tmp` and `/var/run` rather than `/etc`.

## FAQ

**How does 2.0 differ from Tachyon 1.x?**
Version 2.0 replaces legacy `ucode` scripts and third-party cores with a unified native Rust service (`/usr/bin/tachyon`) paired with `tachyon-core`, bringing lower CPU/RAM overhead, `.trs` rule sets, 14 balancer modes, native packet desynchronization, Agent REST API v1, and an embedded MCP server.

**Do I need to rebuild my 1.x configuration manually?**
No. Installing 2.0 automatically imports `/etc/config/tachyon` into `/etc/tachyon/tachyon.json` while keeping a backup. You can also trigger migration manually via `tachyon import-legacy`.

**Do existing `.srs` rule-set URLs still work in 2.0?**
Yes. User-supplied third-party `.srs` URLs continue to work as compatibility fallbacks, while all built-in presets and lists default to native `.trs`.

**How do I switch back from beta/rc releases to stable?**
Under `Settings -> Lists & Presets`, set **`Update channel`** to **`Stable only`** (`stable`) and save, or re-run `install.sh --channel stable`.

---

[Previous: Updates, Channels, and System Settings](11-updates-settings.md) | [Back to Index](README.md) | [Next: CLI and Configuration Reference](13-cli-and-config.md)
