# 04. DPI Bypass & Desynchronization Engines

Tachyon integrates three distinct local packet desynchronization engines that operate entirely on the router hardware without requiring an external proxy server (Zero-VPS mode).

---

## 1. Comparison Matrix: Zapret v1 vs Zapret v2 vs ByeDPI

| Feature | Zapret v1 (`nfqws`) | Zapret v2 (`nfqws2`) | ByeDPI (`ciadpi`) |
|---|---|---|---|
| **Binary** | `/usr/bin/nfqws` | `/usr/bin/nfqws2` | `/usr/bin/ciadpi` |
| **Operating Model** | Kernel NFQueue Intercept | Kernel NFQueue Multi-Q | Local SOCKS5 / TProxy |
| **Target Protocols** | HTTP, TLS (ClientHello) | HTTP, TLS, QUIC, WireGuard | HTTP, TLS |
| **Packet Splitting** | `split2`, `disorder`, `fake` | `multisplit`, `seqovl`, `wsize`, `fake` | `--split-pos`, `--disorder`, `--fake` |
| **Multi-Vector Chains** | Single strategy per rule | Multi-phase composite chains | Composite SOCKS args |
| **CPU Overhead** | Minimal (< 1%) | Low (< 2%) | Low (< 2%) |
| **Best For** | Legacy OpenWrt, Basic DPI | YouTube 4K, Discord, TSPU | Non-root users, SOCKS routing |

---

## 2. Desynchronization Techniques Explained

Deep Packet Inspection (DPI) systems inspect packet headers (such as TLS Server Name Indication `SNI` or HTTP `Host` headers) to detect and block access. Desynchronization tricks the DPI into losing track of the connection state while the destination server reconstructs the stream normally.

```
Original Stream:   [TLS ClientHello with SNI] ──────────► (Blocked by DPI)

Desynchronized:    [Fake Bad Checksum Packet] ──────────► (DPI resets state)
                   [Payload Part 1: Snippet]  ──────────► (DPI misses SNI)
                   [Payload Part 2: Remainder] ─────────► (Server merges stream)
```

### 2.1. Key Desync Strategies

1. **`split2` / `multisplit`**:
   * Splits the TCP segment right inside the TLS SNI or HTTP Host header. The DPI does not reassemble small fragments, while the end server's TCP stack reconstructs the full buffer seamlessly.
2. **`disorder` / `disorder2`**:
   * Sends the second half of the packet before the first half with appropriate TCP sequence numbers. The DPI sees out-of-order data and skips inspection.
3. **`fake` / `fake_sni`**:
   * Sends a fake TLS ClientHello packet with a low TTL (Time To Live). The DPI intercepts the fake packet and approves the connection; the packet dies before reaching the destination server.
4. **`seqovl` (Sequence Overlap)**:
   * Sends a fake packet with overlapping sequence numbers that the server's TCP stack discards while the DPI's state machine is fooled.
5. **`wsize` (Window Size Manipulation)**:
   * Forces a small TCP window size to prevent DPI from receiving full payloads in single bursts.

---

## 3. Configuration & Runtime Management

### 3.1. Zapret v2 Configuration Example (`/etc/config/tachyon`)

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

### 3.2. ByeDPI Configuration Example

```ini
config provider 'byedpi'
    option enabled '1'
    option daemon_bin '/usr/bin/ciadpi'
    option listen_ip '127.0.0.1'
    option listen_port '1080'
    option args '--split-pos 1 --disorder 1 --fake -1 --ttl 8'
```

---

## 4. NFQueue Multiplexing & Conflict Prevention

* Kernel `nfnetlink_queue` requires unique queue numbers per daemon instance.
* Tachyon's `providers/nfqueue/runtime.uc` dynamically manages queue allocation:
  * Default Zapret v1 queue: `200`
  * Default Zapret v2 queue: `201`
* If both Zapret v1 and v2 are enabled simultaneously for different rules, Tachyon enforces strict queue isolation and prevents PID collisions.
