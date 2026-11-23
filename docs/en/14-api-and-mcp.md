# Agent REST API and MCP Server

[Русский](../ru/14-api-and-mcp.md) | [Back to Index](README.md)

Tachyon 2.0 exposes a machine-readable **Agent REST API** and a built-in **Model Context Protocol (MCP)** JSON-RPC 2.0 server for automation, monitoring integrations, and AI engineering assistants.

## Authentication and Security (`src/api.rs`)

Requests to `/api/agent/v1/*` and HTTP `/mcp` are authorized via any of three mechanisms:

1. **Agent API Bearer Token**: pass `Authorization: Bearer <agent_api_token>` configured in `settings.agent_api_token`. Secret fields returned by config endpoints are automatically masked as `[REDACTED]`.
2. **Web Session Cookie**: `tachyon_session` cookie issued by `POST /api/login`.
3. **Trusted Local Network**: requests originating from `localhost`, trusted LAN subnets, or an authorized Tailscale peer (when enabled).

> [!IMPORTANT]
> Sensitive credential fields (`agent_api_token`, `clash_api_secret`, `server_subscription_token`, `new_password`) are protected against accidental overwrite via generic settings endpoints.

## Agent REST API Endpoints (`/api/agent/v1/*`)

A live machine-readable schema is served directly by the router:

- `GET /api/agent/v1/openapi.json` — OpenAPI specification for typed client generation.

### Core Endpoints

| Method & Path | Purpose |
|---|---|
| `GET /api/agent/v1/health` | Lightweight service and engine liveness status |
| `GET /api/agent/v1/snapshot` | Consolidated router and telemetry snapshot |
| `GET /api/agent/v1/config` | Redacted runtime configuration store (`[REDACTED]` secrets) |
| `POST /api/agent/v1/config/plan` | Validate configuration and detect rule collisions (also `GET /api/diagnostics/config-plan`) |
| `POST /api/agent/v1/config/set` | Apply settings updates |
| `GET /api/agent/v1/diagnose` | Full `Doctor` diagnostic report |
| `POST /api/agent/v1/ai-doctor` | Run AI Doctor diagnostic analysis |
| `POST /api/agent/v1/ai-doctor/fix` / `/heal` | Execute automated diagnostic remediation |
| `GET /api/agent/v1/route/explain` | Simulate routing for a target host, port, protocol, and client IP |
| `POST /api/agent/v1/domain/add` | Append a `domain` rule to a target `section_id` |
| `POST /api/agent/v1/section/toggle` | Enable or disable a routing section |
| `POST /api/agent/v1/reload` / `/restart` | Recompile configuration and reload or restart `tachyon-core` |
| `GET /api/agent/v1/logs` | Recent structured daemon and core logs |
| `GET /api/agent/v1/support-bundle` | Build redacted `support_bundle` archive |
| `GET /api/agent/v1/known-good` | Inspect Last Known Good (`LKG`) configuration status |
| `GET /api/agent/v1/docs/search` | Query built-in router troubleshooting knowledge base |

Additional web UI telemetry endpoints (`/api/telemetry`, `/api/bootstrap`, `/api/core/connections`, `/api/dns/block-stats`, etc.) are also exposed on the same listener.

### `curl` Examples

Check health and trace a route decision:

```sh
curl -fsS -H "Authorization: Bearer YOUR_AGENT_TOKEN" \
  http://192.168.1.1:1680/api/agent/v1/health

curl -fsS -H "Authorization: Bearer YOUR_AGENT_TOKEN" \
  "http://192.168.1.1:1680/api/agent/v1/route/explain?target=example.com&client_ip=192.168.1.10"
```

## Embedded MCP Server (`src/mcp.rs`)

Tachyon 2.0 supports two **Model Context Protocol (JSON-RPC 2.0)** transports:

1. **HTTP**: `POST http://<router>:1680/mcp` or `POST http://<router>:1680/api/agent/v1/mcp` (with `Authorization: Bearer <token>`).
2. **Stdio (local or over SSH)**: `tachyon mcp`.

### Complete List of All 11 MCP Tools

| Tool Name | Arguments (`inputSchema`) | Description |
|---|---|---|
| `get_status` | `{}` | Returns redacted system, `tachyon-core`, and Doctor health summary |
| `route_explain` | `target` (*required*), `client_ip`, `port`, `protocol` | Simulates packet routing across active sections and conditions |
| `config_plan` | `{}` | Validates current configuration and checks for collisions |
| `apply_quick_fix` | `fix_id` (*required*), `dry_run`, `force` | Runs an automated quick-fix remediation with before/after verification or dry-run preview |
| `get_core_health` | `{}` | Returns live `tachyon-core` telemetry: memory, file descriptors, UDP NAT, FakeIP pool, DNS servers, and per-outbound `DialErrorClass` counters |
| `get_anomalies` | `{}` | Lists domains experiencing repeated connection failures over the last 5 minutes |
| `get_flight_failures` | `outbound`, `limit` | Retrieves recent failed or zero-transfer sessions from Flight Recorder with `error_kind` and `dial_ms` |
| `get_core_logs` | `level`, `limit` | Fetches recent structured `tachyon-core` log entries filtered by severity |
| `capture_blackbox` | `reason` | Captures an anonymized diagnostic Blackbox snapshot to `tmpfs` (zero NAND flash wear) |
| `flush_dns` | `scope` (`cache`, `upstream`, `all`) | Flushes `tachyon-core` DNS response cache and/or upstream resolution cache |
| `reset_outbound` | `tag` (*required*), `close_sessions`, `stalled_only_ms` | Resets/rebinds an outbound (e.g. WireGuard rebind or URLTest probe) and optionally closes stalled streams |

### MCP Client Configuration Examples

**HTTP Transport (`POST /mcp`):**

```json
{
  "mcpServers": {
    "tachyon-router": {
      "url": "http://192.168.1.1:1680/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_AGENT_TOKEN"
      }
    }
  }
}
```

**SSH `stdio` Transport:**

```json
{
  "mcpServers": {
    "tachyon-router-ssh": {
      "command": "ssh",
      "args": ["root@192.168.1.1", "tachyon", "mcp"]
    }
  }
}
```

---

[Previous: CLI and Configuration Reference](13-cli-and-config.md) | [Back to Index](README.md)
