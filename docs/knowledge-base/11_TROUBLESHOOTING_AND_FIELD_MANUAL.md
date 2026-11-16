# 11. Troubleshooting & Field Diagnostic Manual

A comprehensive guide for diagnosing and resolving common network, proxy, and routing issues on OpenWrt routers running Tachyon.

---

## 1. Quick Emergency Recovery

If router traffic drops completely or DNS resolution is broken, use the **Emergency Native Internet Restoration** command:

```sh
tachyon apply_quick_fix restore_native_internet
```

This performs the following actions in under 200 ms:
1. Atomically drops all nftables interception tables (`nft delete table inet TachyonTable`).
2. Clears policy routing `table tachyon` (ID `205`) and `ip rule` entries (`fwmark 0x04000000/0x04000000`).
3. Restores `dnsmasq` to stock upstream forwarders (`tachyon restore_dnsmasq`).
4. Stops `tachyon` service without rebooting the router.

---

## 2. Symptom Resolution Matrix

| Symptom | Likely Cause | Recommended Fix / Command |
|---|---|---|
| **Websites fail to open, ping to 8.8.8.8 works** | DNS loop, missing bootstrap DNS, or `dnsmasq` forwarder crash. | `tachyon apply_quick_fix clear_dns_cache,fix_dnsmasq` or `fix_bootstrap_dns` |
| **YouTube 4K buffers or stalls** | Packet desynchronization profile does not match current route behavior. | Switch the `desync` section to `desync_preset='auto'` (Adaptive 2.0) or run Strategy Fuzzer (`tachyon fuzzer_start desync youtube_suite`). |
| **`tachyon-core` fails to start** | Invalid outbound parameter, port collision, or malformed config field. | Run `tachyon config_plan --json` and `tachyon doctor`; inspect `/tmp/tachyon-core/tachyon-core.log`. |
| **System clock desynchronized, TLS/DoH fails** | Router rebooted without RTC battery, NTP desync. | `tachyon apply_quick_fix fix_system_time` |
| **High latency or packet drop under heavy load** | Kernel `nf_conntrack` table overflow. | `tachyon apply_quick_fix flush_conntrack` |
| **AmneziaWG / WireGuard handshake succeeds but large pages stall** | Tunnel MTU / MSS clamping mismatch. | `tachyon apply_quick_fix optimize_mtu` |
| **Router runs out of RAM (OOM Crash)** | Memory pressure on 128 MB RAM router or bloated temporary caches. | `tachyon apply_quick_fix optimize_memory` |
| **Firewall reload (`fw4`) wiped custom rules** | System firewall restarted externally without reloading `inet TachyonTable`. | Reconciler (`tachyon reconciler reconcile`) or `tachyon apply_quick_fix rebuild_rules`. |

---

## 3. Diagnostic Commands Reference

```sh
# 1. Run local offline rule checks and live verification
tachyon doctor
tachyon diagnose_json

# 2. Trace exact DNS, nftables, and outbound decision for any domain or IP
tachyon route_explain "" youtube.com 443 tcp --json

# 3. Validate UCI configuration and check for shadowing/port collisions (dry-run)
tachyon config_plan --json

# 4. Run declarative drift detection and targeted self-repair (Reconciler)
tachyon reconciler status
tachyon reconciler reconcile

# 5. Inspect or roll back to Last Known Good (LKG) snapshot
tachyon known_good status
tachyon known_good rollback

# 6. Run AI Doctor with LLM analysis (all inputs pre-redacted)
tachyon ai_doctor

# 7. Inspect active nftables firewall tables and policy routing table 'tachyon' (205)
nft list table inet TachyonTable
ip route show table tachyon
ip rule show

# 8. Check listening ports (TProxy 1602, Core DNS 127.0.0.42:53, Clash API 9090)
netstat -tulpn | grep -E 'tachyon-core|1602|9090|:53'

# 9. Export a SHA-256 verified, fully redacted diagnostic support archive
tachyon support_bundle
```

---

## 4. Runtime & Log Inspection Paths

| Path | Content Description |
|---|---|
| `/var/run/tachyon/events.jsonl` | Bounded structured event ring journal (secrets redacted at write time). |
| `/tmp/tachyon_ai_status.json` | Real-time Watchdog telemetry, fail streaks, and active repairs. |
| `/tmp/ai_doctor_last.json` | Redacted JSON report of the most recent AI Doctor diagnosis. |
| `/etc/tachyon-core/config.json` | Generated runtime configuration for `tachyon-core`. |
| `/etc/tachyon/state/known_good/` | Persistent Last Known Good (LKG) configuration and manifest. |
| `/var/run/tachyon/tx/` | Active transaction snapshots and rollback journals (`core/transaction.uc`). |
