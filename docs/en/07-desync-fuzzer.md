# Packet Desynchronization and Fuzzer

[Русский](../ru/07-desync-fuzzer.md) | [Back to Index](README.md)

For traffic paths where direct provider delivery needs packet-level resilience without forwarding through an external proxy server, `tachyon-core` includes a native **packet desynchronization (`desync`)** engine running inside the main core process.

## Purpose and Workflow

A `desync` outbound source modifies initial TCP/TLS packet framing (TLS record splitting, ClientHello fragmentation, controlled TTL decoy packets, TCP sequence overlap, and UDP padding/repeats) so connections complete cleanly across middlebox inspection or strict transit packet filters.

Standard setup workflow:

1. In `Routing -> Nodes & Sources`, add a source with type **`Desync`**.
2. In `Routing -> Routing Sections`, create a section with action **`Desync`** and attach your `.trs` rule sets or domain lists (or select the proxy-free preset in the Quick Connection Wizard).

## Presets and Adaptive 2.0 (`auto_tune`)

The **`desync_preset`** field selects the baseline strategy:

- **`auto` (Adaptive 2.0)**: recommended default — selects fragmentation defaults automatically and adapts to network path responses.
- Built-in presets: `split`, `multisplit`, `disorder`, `multi_disorder`, `fake`, `fake_split`, `fake_disorder`.
- **`custom`**: full manual control or strategy arguments imported directly from the built-in strategy fuzzer.

When **`desync_auto_tune`** (Adaptive 2.0 Auto-Learning) is enabled, the engine monitors live flow anomalies — unexpected `TCP RST`, handshake stalls, or speed throttling (`< 20 KiB/s`) — rotates strategies automatically, and caches the working per-SNI profile inside `cache.db` so subsequent connections succeed immediately.

## Manual Strategy Parameters

| Field | Purpose |
|---|---|
| `desync_mode` | Splitting method (`split`, `multisplit`, `disorder`, `fake`, etc.) |
| `desync_split_pos` | Split offset markers (`midsld`, `sni`, `sniext+1`, `host+1`, `endhost-1`, `extlen`, numeric byte offset `1..1400`, or comma-separated list e.g. `1,sniext+1,midsld`) |
| `desync_tlsrec_first` | Splits the TLS record layer (`TLS Record Split`) prior to TCP segmentation |
| `desync_fooling` | Marker applied to decoy packets so intermediate transit middleboxes drop them before reaching the origin (`badsum`, `md5sig`, `ts`, etc.) |
| `desync_fake_ttl` | Constrained `TTL` for decoy packets (`autottl` or numeric hop limit) |
| `desync_repeats` | Number of decoy packet repetitions |
| `desync_seqovl` | TCP sequence-number overlap offset during split |
| `desync_fake_sni` / `desync_sni_pool` | Custom SNI header or rotating pool, alongside `desync_fake_tls` and `desync_fake_payload` |
| `desync_wsize` / `desync_wscale` | TCP receive window and window-scale control to stabilize handshakes |
| `desync_split_delay_ms` | Inter-segment transmission delay (ms) |
| `desync_ipfrag` | IP-layer packet fragmentation toggle |
| UDP options | `desync_udp_fake`, `desync_udp_repeats`, `desync_udp_fake_ttl`, `desync_udp_fake_payload`, `desync_udp_out_range`, `desync_udp_keep_socket`, `desync_udplen` for QUIC and UDP flows |

## Built-in Strategy Fuzzer

Directly from the `desync` source modal (as well as Diagnostics and the `/fuzzer` Telegram command), you can launch the **Strategy Fuzzer**:

- Probes combinations of split offsets, fooling flags, and TTL limits directly from the router against a test domain.
- Applies the best verified strategy in one click (switching the source to `custom` and populating `desync_opts`).

---

[Previous: Inbound Servers and Tailscale](06-inbound-servers-tailscale.md) | [Back to Index](README.md) | [Next: Devices, Parental Control, Guest Mode, and QoS](08-devices-parental-guest-qos.md)
