# 08. Complete UCI Configuration Schema Reference

The primary configuration for Tachyon is stored at `/etc/config/tachyon` (UCI format, mode `0600`).

---

## 1. Section: `config settings 'settings'`

Global settings defining service behaviour, DNS resolution, watchdog parameters, Telegram integration, and AI Doctor.

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` (`0`/`1`) | `1` | Master toggle for Tachyon service. |
| `log_level` | `string` | `info` | Logging verbosity: `debug`, `info`, `warn`, `error`. |
| `dns_mode` | `string` | `doh` | DNS routing mode: `direct`, `doh`, `dot`, `udp`, `hosts_only`. |
| `remote_dns_server` | `string` | `https://1.1.1.1/dns-query` | Upstream secure DNS resolver for proxied domains. |
| `direct_dns_server` | `string` | `77.88.8.8` | Fallback DNS resolver for direct / local domains. |
| `tproxy_port` | `integer` | `10080` | Local TCP/UDP transparent proxy port for sing-box. |
| `dns_port` | `integer` | `5353` | Local DNS listening port for sing-box DNS engine. |
| `clash_api_port` | `integer` | `9090` | sing-box Clash REST API controller port. |
| `clash_api_secret` | `string` | `""` | Secret token for sing-box Clash API. |
| `watchdog_interval` | `integer` | `10` | Watchdog polling interval in seconds (5–60s). |
| `memory_limit_mb` | `integer` | `0` | Dynamic `GOMEMLIMIT` cap in MB (`0` = auto 50% free RAM). |
| `enable_telegram` | `boolean` | `0` | Enable interactive Telegram management bot. |
| `telegram_token` | `string` | `""` | Telegram Bot API token from `@BotFather`. |
| `telegram_chat_id` | `string` | `""` | Allowed Admin Telegram Chat ID(s) (comma-separated). |
| `enable_ai_doctor` | `boolean` | `0` | Enable LLM AI Doctor diagnostic engine. |
| `ai_doctor_provider`| `string` | `openai` | LLM Provider: `openai`, `anthropic`, `deepseek`, `custom`. |
| `ai_doctor_model` | `string` | `""` | Model override (e.g. `gpt-4o-mini`, `claude-3-5-haiku`). |
| `ai_doctor_api_key`| `string` | `""` | API key for the chosen LLM provider. |
| `ai_doctor_custom_url`| `string` | `""` | Custom OpenAI-compatible endpoint URL (e.g. OpenRouter/Ollama). |
| `agent_api_token` | `string` | `""` | Bearer token for HTTP REST Agent API write access. |

---

## 2. Section: `config server 'name'`

Defines an individual manual proxy outbound node.

| Option | Type | Required | Description |
|---|---|---|---|
| `type` | `string` | Yes | Protocol: `vless`, `vmess`, `shadowsocks`, `trojan`, `hysteria2`, `wireguard`. |
| `server` | `string` | Yes | Remote server hostname or IPv4/IPv6 address. |
| `server_port` | `integer` | Yes | Remote server port (e.g. `443`, `8443`). |
| `uuid` | `string` | Conditional | User UUID for VLESS / VMess. |
| `password` | `string` | Conditional | Password for Shadowsocks / Trojan / Hysteria2. |
| `flow` | `string` | No | Flow control: `xtls-rprx-vision` (VLESS). |
| `security` | `string` | No | Security type: `reality`, `tls`, `none`. |
| `sni` | `string` | Conditional | Server Name Indication for TLS / Reality. |
| `pbk` | `string` | Conditional | Public Key for VLESS Reality. |
| `sid` | `string` | Conditional | Short ID for VLESS Reality (hex string). |
| `fingerprint` | `string` | No | TLS fingerprint: `chrome`, `firefox`, `safari`, `randomized`. |
| `method` | `string` | Conditional | Cipher method for Shadowsocks (e.g. `2022-blake3-aes-128-gcm`). |
| `routing_mode` | `string` | No | Routing mode: `rules` (default), `direct`, `section`. |
| `routing_section` | `string` | No | Bound routing section when `routing_mode = 'section'`. |
| `isolate_lan_for_users` | `boolean` | No | Restrict access to private/LAN IP addresses (`1` / `0`). |
| `isolated_users` | `list string` | No | Specific usernames (`auth_user`) restricted from LAN. If empty, restricts all users of the inbound. |
| `isolated_subnets` | `list string` | No | Optional custom subnets to block for isolated users (defaults to `ip_is_private: true`). |
| `custom_route_rules` | `list string` | No | Raw JSON sing-box route rule objects injected before general routing rules. |

---

## 3. Section: `config subscription 'name'`

Defines a remote subscription URL for automated batch node fetching.

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` | `1` | Enable this subscription source. |
| `url` | `string` | Required | HTTPS / HTTP link to subscription (Base64, Clash, SIP002). |
| `update_interval`| `integer` | `86400` | Auto-update interval in seconds (default 24 hours). |
| `custom_user_agent`| `string` | `""` | Custom User-Agent header for subscription request. |
| `filter_keywords` | `list string` | `[]` | Include nodes matching regex/keywords. |
| `exclude_keywords`| `list string` | `[]` | Exclude nodes matching regex/keywords. |

---

## 4. Section: `config rule 'name'`

Defines a selective routing policy.

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` | `1` | Enable this routing rule. |
| `name` | `string` | `""` | Human-readable label for UI. |
| `action` | `string` | `proxy` | Route target: `proxy`, `zapret`, `zapret2`, `byedpi`, `direct`, `hosts`. |
| `target_server` | `string` | `""` | Bound server ID or outbound tag when `action = 'proxy'`. |
| `domain_pattern` | `list string` | `[]` | List of target domains or wildcards (e.g. `*.youtube.com`). |
| `ip_cidr` | `list string` | `[]` | List of IP subnets (e.g. `104.16.0.0/12`). |
| `client_group` | `string` | `""` | Restrict this rule to a specific client device group. |

---

## 5. Section: `config hosts 'name'`

Configures static DNS overrides and remote blocklists ingestion.

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` | `1` | Enable hosts mapping. |
| `dns_hosts` | `list string` | `[]` | Static mappings in format `domain:ip` (e.g. `example.com:1.2.3.4`). |
| `hosts_list_urls` | `list string` | `[]` | External URLs for blocklists (AdAway, StevenBlack). |
| `update_interval` | `integer` | `86400` | Auto-refresh interval in seconds. |

---

## 6. Ready-to-Use Configuration Recipes

### Recipe A: Zero-VPS Local DPI Bypass (YouTube + Discord)
```ini
config settings 'settings'
    option enabled '1'
    option dns_mode 'doh'

config provider 'zapret2'
    option enabled '1'
    option daemon_bin '/usr/bin/nfqws2'
    option qnum '201'
    option args_tcp '--dpi-desync=multisplit --dpi-desync-split-pos=1,midsld --dpi-desync-seqovl=1 --dpi-desync-fooling=badseq'

config rule 'youtube_discord'
    option enabled '1'
    option name 'YouTube & Discord Local Desync'
    option action 'zapret2'
    list domain_pattern 'googlevideo.com'
    list domain_pattern 'youtube.com'
    list domain_pattern 'ytimg.com'
    list domain_pattern 'discord.com'
    list domain_pattern 'discord.gg'
```

### Recipe B: Hybrid Mode (Local Desync for Media + VLESS Reality for Blocked Sites)
```ini
config server 'my_vps'
    option type 'vless'
    option server 'vps.example.com'
    option server_port '443'
    option uuid '12345678-1234-1234-1234-123456789abc'
    option flow 'xtls-rprx-vision'
    option security 'reality'
    option sni 'yahoo.com'
    option pbk 'XYZ...PUBLIC_KEY...'
    option sid '1a2b3c4d'

config rule 'media_rule'
    option enabled '1'
    option action 'zapret2'
    list domain_pattern 'youtube.com'
    list domain_pattern 'googlevideo.com'

config rule 'blocked_rule'
    option enabled '1'
    option action 'proxy'
    option target_server 'my_vps'
    list domain_pattern 'instagram.com'
    list domain_pattern 'twitter.com'
    list domain_pattern 'x.com'
```
