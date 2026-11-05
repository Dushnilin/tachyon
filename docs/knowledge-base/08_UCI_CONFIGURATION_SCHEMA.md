# 08. Complete UCI Configuration Schema Reference

The primary configuration for Tachyon is stored at `/etc/config/tachyon` (UCI format, mode `0600`).
Tachyon uses a **modular relational UCI schema**: a routing `section` orchestrates traffic by referencing reusable `condition`, `outbound_source`, `balancer`, and `outbound_group` entities.

---

## 1. Global Settings: `config settings 'settings'`

Global settings defining the active routing engine (`tachyon-core` or `sing-box`), DNS resolution, intercepted LAN interfaces, watchdog parameters, Smart Detect, AI Doctor, and Agent API.

| Option | Type | Default | Description |
|---|---|---|---|
| `engine` | `string` | `tachyon-core` | Active routing engine: `tachyon-core` or `sing-box`. |
| `dns_type` | `string` | `doh` | Upstream DNS protocol: `doh`, `dot`, or `udp`. |
| `dns_server` | `string` / `list` | `1.1.1.1` | Remote DNS resolver(s) for proxied / FakeIP resolution. |
| `bootstrap_dns_server` | `string` / `list` | `77.88.8.8` | Direct WAN bootstrap DNS resolver(s) used to resolve outbound server hostnames without circular deadlocks. |
| `fallback_dns_server` | `string` | `8.8.8.8` | Secondary fallback DNS resolver. |
| `dns_rewrite_ttl` | `integer` | `60` | DNS TTL rewrite value (seconds) for intercepted responses (`127.0.0.42:53`). |
| `source_network_interfaces` | `list string` | `['br-lan']` | LAN interfaces intercepted by `inet TachyonTable` (TProxy `:1602`). |
| `enable_ipv6` | `boolean` (`0`/`1`) | `0` | Enable IPv6 routing and `inet TachyonTable` IPv6 sets. |
| `enable_watchdog` | `boolean` (`0`/`1`) | `1` | Enable autonomous Watchdog supervisor and Reconciler drift checks. |
| `enable_smart_detect` | `boolean` (`0`/`1`) | `0` | Enable Smart Detect degraded-domain detection. |
| `smart_detect_mode` | `string` | `default` | Smart Detect mode: `default` or `plus`. |
| `recovery_bypass` | `boolean` (`0`/`1`) | `0` | Emergency bypass mode allowing direct traffic on tunnel failure. |
| `enable_ai_doctor` | `boolean` (`0`/`1`) | `0` | Enable LLM AI Doctor diagnostic engine. |
| `enable_rag` | `boolean` (`0`/`1`) | `1` | Enable hybrid RAG knowledge base retrieval (`/usr/lib/tachyon/rag_index.json`). |
| `ai_doctor_provider` | `string` | `openai` | LLM Provider: `openai`, `anthropic`, `gemini`, `deepseek`, `openrouter`, `groq`, `xai`, `mistral`, `ollama`, `lmstudio`, `custom`. |
| `ai_doctor_model` | `string` | `""` | Model override (e.g. `gpt-4o-mini`, `claude-3-5-haiku-20241022`, `deepseek-chat`, `gemini-2.5-flash`). |
| `ai_doctor_api_key` | `string` | `""` | API key for the chosen LLM provider (redacted in all API/log outputs). |
| `ai_doctor_custom_url` | `string` | `""` | Custom OpenAI-compatible chat/embeddings endpoint URL. |
| `ai_doctor_lang` | `string` | `ru` | AI Doctor output language (`ru` or `en`). |
| `agent_api_token` | `string` | `""` | Bearer token for HTTP REST Agent API & MCP write access. |
| `clash_api_secret` | `string` | `""` | Secret token for local Clash API (`127.0.0.1:9090`). |

---

## 2. Routing Section Orchestrator: `config section '<id>'`

Each `section` binds traffic conditions (`condition_refs`) to an action/outbound (`outbound_source_refs`, `balancer_refs`, or `outbound_group_ref`).

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` | `1` | Enable or disable this routing section. |
| `label` | `string` | `""` | Human-readable section name in LuCI UI. |
| `connection_type` | `string` | `proxy` | Section type: `proxy`, `vpn`, `direct`, `block`, `hosts`, `zapret`, `zapret2`, `byedpi`, `wdtt`, `olcrtc`, `fptn`, `desync`. |
| `action` | `string` | `proxy` | Action mode corresponding to `connection_type`. |
| `condition_refs` | `list string` | `[]` | References to `condition` sections that select traffic for this rule. |
| `outbound_source_refs` | `list string` | `[]` | References to `outbound_source` sections providing proxy nodes or local providers. |
| `balancer_refs` | `list string` | `[]` | References to `balancer` sections for latency/weighted load distribution. |
| `outbound_group_ref` | `string` | `""` | Reference to an `outbound_group` section for primary/backup failover cascade. |

---

## 3. Traffic Matcher: `config condition '<id>'`

Defines reusable atomic or composite (`all` / `any` / `not`) matching criteria.

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` | `1` | Enable this condition. |
| `name` | `string` | `""` | Condition display name. |
| `condition_type` | `string` | `atomic` | `atomic`, `all`, `any`, or `not` (composite conditions use `children`). |
| `community_lists` | `list string` | `[]` | Built-in community domain/IP lists (`youtube`, `discord`, `telegram`, `meta`, `openai`, etc.). |
| `user_domains` | `list string` | `[]` | Custom domains and suffixes (e.g. `example.com`, `googlevideo.com`). |
| `user_subnets` | `list string` | `[]` | Custom destination IPv4/IPv6 CIDR subnets. |
| `remote_domain_lists` | `list string` | `[]` | Remote URLs of domain lists. |
| `remote_subnet_lists` | `list string` | `[]` | Remote URLs of IP CIDR lists. |
| `geoip_codes` | `list string` | `[]` | GeoIP country codes. |
| `geosite_codes` | `list string` | `[]` | GeoSite category codes. |
| `client_ips` | `list string` | `[]` | Match specific LAN client IPv4/IPv6 addresses. |
| `exclude_client_ips` | `list string` | `[]` | Exclude specific LAN client IPs from matching. |
| `ports` | `list string` | `[]` | Destination ports or ranges (e.g. `443`, `50000-65535`). |
| `l4_proto` | `string` | `""` | Layer-4 protocol filter: `tcp`, `udp`, or empty (both). |

---

## 4. Outbound Source: `config outbound_source '<id>'`

Defines proxy subscriptions, manual proxy links, raw JSON outbounds, network interfaces, or local provider strategies.

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` | `1` | Enable this outbound source. |
| `name` | `string` | `""` | Human-readable source name. |
| `source_type` | `string` | `subscription` | `subscription`, `proxy_links`, `custom_json`, `interface`, or `provider`. |
| `subscription_urls` | `list string` | `[]` | Subscription URLs (`https://...`) when `source_type = 'subscription'`. |
| `proxy_links` | `list string` | `[]` | Direct proxy URIs (`vless://`, `vmess://`, `ss://`, `trojan://`, `hysteria2://`, `wireguard://`, `awg://`). |
| `custom_json` | `string` | `""` | Raw outbound JSON object when `source_type = 'custom_json'`. |
| `interface_name` | `string` | `""` | Network interface name (e.g. `wg0`, `awg0`, `tun0`) when `source_type = 'interface'`. |
| `provider_kind` | `string` | `""` | Local provider type: `zapret`, `zapret2`, `byedpi`, `wdtt`, `olcrtc`, `fptn`, `desync`. |
| `nfqws2_strategy` | `string` | `""` | Zapret v2 Lua strategy (`--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq`). |
| `nfqws_strategy` | `string` | `""` | Zapret v1 strategy (`--dpi-desync=fake,split2 --dpi-desync-split-pos=1,midsld`). |
| `byedpi_args` | `string` | `""` | ByeDPI (`ciadpi`) CLI arguments (`-s 1 -d 1 --auto=t,r,s -o 1`). |
| `filter_allow_regex` | `string` | `""` | Include subscription nodes matching regex. |
| `filter_deny_regex` | `string` | `""` | Exclude subscription nodes matching regex. |

---

## 5. Balancers & Failover Groups: `config balancer '<id>'` & `config outbound_group '<id>'`

### 5.1. `config balancer '<id>'`
Distributes or selects across nodes from `outbound_source_refs`:
* `balancer_type`: `urltest` (default) or `priority`.
* `mode`: `least_test`, `least_ping`, `round_robin`, `random`, `stability`.
* `testing_url`: Probe URL (default `https://www.gstatic.com/generate_204`).
* `check_interval`: Probe interval in seconds (default `180`).
* `tolerance`: Latency switch threshold in ms (default `50`).
* `sticky_hash`: Sticky hash key (`src_ip`, `dst_ip`, `dst_host`).
* `passive_check`: Enable passive failure tracking (`0`/`1`).

### 5.2. `config outbound_group '<id>'`
Defines a multi-tier failover cascade:
* `primary_refs`: Primary `outbound_source` or `balancer` IDs.
* `backup_refs`: Backup `outbound_source` or `balancer` IDs activated when primaries fail.
* `fail_policy`: Behavior when all tiers fail (`block`, `direct`, or `last_alive`).

---

## 6. Inbound Server Node: `config server '<id>'`

Defines an inbound server hosted on the router (`shadowsocks`, `vless`, `vmess`, `trojan`, `socks`, `http`, `wireguard`):
* `routing_mode`: `rules` (default), `direct`, or `section` (bound to `routing_section`).
* `isolate_lan_for_users`, `isolated_users`, `isolated_subnets`: Restrict inbound clients from accessing private LAN subnets.
* When saving in LuCI, disabling a routing section also disables enabled servers with `routing_mode = 'section'` and a matching `routing_section`. Their routing settings are preserved; enabling the section again does not automatically enable the servers.

---

## 7. Ready-to-Use Configuration Recipes

### Recipe A: Zero-VPS Local Packet Desynchronization (YouTube + Discord via Zapret v2)
```ini
config settings 'settings'
    option engine 'tachyon-core'
    option dns_type 'doh'
    option bootstrap_dns_server '77.88.8.8'

config condition 'cond_media'
    option enabled '1'
    option name 'YouTube & Discord'
    option condition_type 'atomic'
    list community_lists 'youtube'
    list community_lists 'discord'
    list user_domains 'googlevideo.com'

config outbound_source 'src_zapret2'
    option enabled '1'
    option name 'Zapret2 Multisplit'
    option source_type 'provider'
    option provider_kind 'zapret2'
    option nfqws2_strategy '--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq'

config section 'sec_media'
    option enabled '1'
    option label 'Media Local Desync'
    option connection_type 'zapret2'
    option action 'zapret2'
    list condition_refs 'cond_media'
    list outbound_source_refs 'src_zapret2'
```

### Recipe B: Hybrid Mode (Zapret v2 for Media + VLESS Reality Subscription with Balancer)
```ini
config outbound_source 'src_vps_sub'
    option enabled '1'
    option name 'Main Subscription'
    option source_type 'subscription'
    list subscription_urls 'https://sub.example.com/api/v1/client/subscribe?token=REDACTED'

config balancer 'bal_fastest'
    option enabled '1'
    option name 'Fastest EU Node'
    option balancer_type 'urltest'
    option mode 'least_ping'
    option check_interval '180'
    option tolerance '50'
    list outbound_source_refs 'src_vps_sub'

config condition 'cond_proxied'
    option enabled '1'
    option name 'Proxied Services'
    option condition_type 'atomic'
    list community_lists 'openai'
    list user_domains 'example.org'

config section 'sec_proxy'
    option enabled '1'
    option label 'Main Proxy Route'
    option connection_type 'proxy'
    option action 'proxy'
    list condition_refs 'cond_proxied'
    list balancer_refs 'bal_fastest'
```
