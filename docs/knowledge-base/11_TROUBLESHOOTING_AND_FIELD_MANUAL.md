# 11. Troubleshooting & Field Diagnostic Manual

A comprehensive guide for diagnosing and resolving common network, proxy, and routing issues on OpenWrt routers running Tachyon.

---

## 1. Quick Emergency Recovery

If router traffic drops completely or DNS resolution is broken, use the **Emergency Native Internet Restoration** command:

```sh
tachyon restore_native_internet
```

This performs the following actions in under 200 ms:
1. Atomically drops all nftables interception tables (`nft delete table inet TachyonTable`).
2. Clears policy routing `table 100` and `ip rule` entries.
3. Restores dnsmasq to stock upstream forwarders.
4. Stops sing-box and DPI bypass daemons without rebooting the router.

---

## 2. Symptom Resolution Matrix

| Symptom | Likely Cause | Recommended Fix / Command |
|---|---|---|
| **Websites fail to open, ping to 8.8.8.8 works** | DNS loop or dnsmasq forwarder crash. | `tachyon apply_quick_fix clear_dns_cache,fix_dnsmasq` |
| **YouTube 4K buffers indefinitely** | Zapret strategy out-of-date for current ISP. | Switch Zapret v2 strategy to `multisplit` with `seqovl=1`. |
| **sing-box fails to start after config change** | Syntax error in custom outbound or invalid UUID. | Check `/var/log/tachyon_service.log` and run `tachyon doctor`. |
| **System clock desynchronized, TLS fails** | Router rebooted without RTC battery, NTP desync. | `tachyon apply_quick_fix fix_system_time` |
| **High latency or packet drop under heavy load** | Kernel `nf_conntrack` table overflow. | `tachyon apply_quick_fix flush_conntrack` |
| **VLESS Reality connection timeout** | Reality SNI domain blocked or expired short ID. | Update server SNI to accessible target (e.g. `yahoo.com`). |
| **Router runs out of RAM (OOM Crash)** | sing-box buffer explosion on low-RAM device (128 MB). | Lower `memory_limit_mb` in UCI settings (`GOMEMLIMIT=40MiB`). |

---

## 3. Diagnostic Commands Reference

```sh
# 1. Run local offline rule checks
tachyon doctor

# 2. Run AI Doctor with LLM analysis
tachyon ai_doctor

# 3. View real-time Watchdog telemetry
tachyon ai_status_full

# 4. Inspect active nftables firewall tables
nft list table inet TachyonTable

# 5. Inspect policy routing table 100
ip route show table 100
ip rule show

# 6. Stream live Tachyon system logs
logread -f -e tachyon

# 7. Check listening ports (TProxy 10080, DNS 5353, Clash 9090)
netstat -tulpn | grep -E 'sing-box|tachyon|5353|10080'
```

---

## 4. Log Inspection Paths

| Log Location | Content Description |
|---|---|
| `/var/log/tachyon_service.log` | Core service lifecycle events (start, stop, reload). |
| `/var/log/tachyon_watchdog.log` | Background supervisor health checks and loop warnings. |
| `/tmp/ai_doctor_last.json` | JSON report of the most recent AI Doctor diagnosis. |
| `/tmp/tachyon/sing-box.json` | Generated live configuration compiled for sing-box. |
| `/tmp/tachyon/hosts/combined.txt` | Consolidated deduplicated hosts list. |
