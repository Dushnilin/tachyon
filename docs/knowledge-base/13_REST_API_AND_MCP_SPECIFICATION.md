# 13. HTTP REST Agent API & Model Context Protocol (MCP) Specification

Tachyon provides a standardized RESTful Agent API and Model Context Protocol (MCP) integration, enabling seamless orchestration by autonomous LLM agents (ChatGPT Actions, Claude Code, Cursor, Windsurf, N8N, Dify).

---

## 1. REST API Overview

* **Base URL**: `http://<router-ip>/cgi-bin/tachyon-agent/`
* **OpenAPI Schema**: `http://<router-ip>/cgi-bin/tachyon-agent/openapi.json`
* **Content-Type**: `application/json`

---

## 2. Authentication Model

1. **Read-Only Endpoints**: Unrestricted when accessed from local LAN.
2. **Write Endpoints**: Require HTTP Authorization header:
   ```http
   Authorization: Bearer <agent_api_token>
   ```

---

## 3. Endpoint Reference & Payloads

### 3.1. `GET /health`
Returns lightweight status of all core daemons.
```json
{
  "status": "healthy",
  "version": "1.2.86",
  "uptime_seconds": 18450,
  "singbox_running": true,
  "watchdog_running": true,
  "active_server": "Frankfurt_VLESS_Reality"
}
```

### 3.2. `GET /diagnose`
Returns Local Rule Doctor checks and suggested repair codes.
```json
{
  "status": "warning",
  "checks": {
    "dns_loop": false,
    "conntrack_full": false,
    "time_desync": true,
    "singbox_ok": true
  },
  "suggested_fixes": ["fix_system_time"]
}
```

### 3.3. `POST /ai-doctor/fix`
Applies one or more quick-fix codes.
* **Request**:
  ```json
  {
    "fix": "clear_dns_cache,start_singbox"
  }
  ```
* **Response**:
  ```json
  {
    "success": true,
    "applied_fixes": ["clear_dns_cache", "start_singbox"],
    "details": "DNS cache cleared. sing-box process restarted."
  }
  ```

---

## 4. Model Context Protocol (MCP) Tool Definitions

For MCP-compatible agents (Cursor, Claude Desktop), Tachyon exports tools via `GET /cgi-bin/tachyon-agent/tools`:

```json
[
  {
    "name": "tachyon_diagnose",
    "description": "Run diagnostic checks on OpenWrt router network and proxy health",
    "input_schema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "tachyon_apply_fix",
    "description": "Apply automated repair codes to fix router network or proxy issues",
    "input_schema": {
      "type": "object",
      "properties": {
        "fix_codes": {
          "type": "string",
          "description": "Comma-separated list of fix codes (e.g. clear_dns_cache,restart_singbox)"
        }
      },
      "required": ["fix_codes"]
    }
  },
  {
    "name": "tachyon_switch_server",
    "description": "Switch active proxy server node",
    "input_schema": {
      "type": "object",
      "properties": {
        "server_id": {
          "type": "string",
          "description": "Identifier of target proxy server"
        }
      },
      "required": ["server_id"]
    }
  }
]
```
