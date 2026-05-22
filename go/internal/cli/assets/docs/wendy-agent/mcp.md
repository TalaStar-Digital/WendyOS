# MCP (Model Context Protocol)

WendyOS has first-class support for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). The wendy agent can expose tools from both the host system and from running app containers to any MCP-compatible AI assistant (Claude Desktop, Cursor, Windsurf, Codex, etc.).

## Overview

```
AI Assistant (Claude Desktop / Cursor / Windsurf / Codex)
        │  MCP (stdio)
        ▼
wendy mcp serve          ← aggregates all tool sources
    │           │
    │           └── StreamMCP gRPC ──► app container (MCP server on TCP port)
    │
    └── built-in host tools (provisioning, OS, cloud, …)
```

`wendy mcp serve` starts a local MCP server over stdio. It:

- Exposes built-in tools for device provisioning, OS management, and cloud operations.
- Discovers running containers that declare the [`mcp` entitlement](#container-mcp-servers) and automatically proxies their tools, prefixed with the app name.

## Setup

### Automatic (recommended)

```sh
wendy mcp setup
```

`wendy mcp setup` detects installed AI tools and writes the `wendy mcp serve` invocation into each one's configuration automatically. Supported tools and their config paths:

| Tool | Config path |
|------|-------------|
| Claude Code | `~/.claude.json` |
| Claude Desktop | `claude_desktop_config.json` (platform default) |
| Cursor | `~/.cursor/mcp.json` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |
| Codex | `~/.codex/config.toml` (TOML, `[mcp_servers.wendy]`) |

Detection uses the presence of the tool's config directory or its binary on `PATH`. Only detected tools are configured. The binary path is resolved using `os.Executable()` without resolving symlinks, so the stable symlink (e.g. `/opt/homebrew/bin/wendy`) is recorded rather than a versioned path — the configuration remains valid across upgrades.

### Manual

Add the following to your MCP client's server configuration:

```json
{
  "mcpServers": {
    "wendy": {
      "command": "/path/to/wendy",
      "args": ["mcp", "serve"]
    }
  }
}
```

For Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.wendy]
command = "wendy"
args = ["mcp", "serve"]
```

## `wendy mcp serve`

Starts the MCP server over stdio. Connects to the default device (or the device specified with `--device`) and registers all available tools.

If the configured address does not include a port, the default agent port is appended automatically.

**What gets registered:**

| Tool group | Source |
|------------|--------|
| Status tool (`wendy_status`) | Built-in |
| Device tools | Built-in |
| Provisioning tools | Built-in |
| OS tools | Built-in |
| Cloud tools | Built-in |
| Container MCP tools | Running containers with `mcp` entitlement (proxied via `StreamMCP`) |

**What gets registered as resources:**

| Resource | URI |
|----------|-----|
| Orientation guide | `wendy://guide` |

The `list_cloud_assets` cloud tool caps results at **10 000 devices** to prevent unbounded memory growth. If the backend returns more, the tool returns an error: `cloud returned more than 10000 devices`.

## Built-in tools

### `wendy_status`

Call this first in any AI session. Returns the current connection state and a suggested next step.

**Response fields:**

| Field | Description |
|-------|-------------|
| `connected` | `true` if an active device connection exists, `false` otherwise |
| `device` | Name of the connected device (when `connected` is `true`) |
| `connection_type` | Transport used: `"direct"` or `"cloud"` (when `connected` is `true`) |
| `suggested_next_step` | Plain-English hint for what to do next |

### `device_list`

Lists wendy devices from config and known addresses.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `scan` | boolean (optional) | When `true`, runs a live 3-second mDNS scan in addition to returning config-known devices |

All results include a `source` field indicating where the entry came from:

| `source` value | Meaning |
|----------------|---------|
| `"config"` | Device is known from the local config file |
| `"scan"` | Device was discovered by the live mDNS scan |

### `run`

Build and deploy a local project to a device (direct or cloud-enrolled). This is the canonical deploy tool for MCP sessions.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `project_path` | string (required) | Project directory containing `wendy.json` |
| `device_name` | string | Target device name |
| `build_type` | string | Build type: `docker`, `swift`, or `python` |
| `product` | string | Swift Package Manager product to build and run |
| `debug` | boolean | Enable debug logging |
| `deploy` | boolean | Create container but do not start it |
| `detach` | boolean | Start container but do not stream logs (default `true` for MCP) |
| `timeout_seconds` | number | Maximum runtime in seconds (default 300) |

`run` does not require a prior `device_connect` or `cloud_connect` call — it manages the connection internally. When the target device is not reachable directly and cloud auth entries exist, `run` falls back to the cloud tunnel automatically.

### `cloud_run` (deprecated)

`cloud_run` is a deprecated alias for `run`. Use `run` instead.

## `wendy://guide` resource

A static orientation document registered at server startup. Read it to understand the connection model and common tool workflows:

```
wendy://guide
```

The resource is served as `text/plain`.

## `wendy run` cloud fallback

`wendy run` (CLI command) first attempts a direct connection to the target device. If the direct connection fails and cloud auth entries exist, it automatically retries through the Wendy Cloud tunnel. This means `--device <name>` works for both locally reachable and cloud-only enrolled devices without specifying different commands.

## `wendy cloud run` (deprecated)

`wendy cloud run` is a hidden alias that injects cloud context and delegates to `wendy run`. Use `wendy run` directly instead.

## Container MCP Servers

Apps can expose their own MCP tools by declaring the `mcp` entitlement in `wendy.json`:

```json
{
  "appId": "com.example.my-mcp-app",
  "version": "1.0.0",
  "language": "python",
  "entitlements": [
    { "type": "network", "mode": "host" },
    { "type": "mcp", "port": 3000 }
  ]
}
```

When the container starts, the agent:

1. Stores `"3000"` in the containerd label `sh.wendy/mcp.port`.
2. Returns the port in the `mcp_port` field of `AppContainer` (visible in `wendy device apps list`).
3. Makes the container's MCP server reachable through the `StreamMCP` gRPC RPC.

When `wendy mcp serve` starts, it scans all running containers for a non-zero `mcp_port` and connects to each one, registering their tools on the aggregated MCP server with the app name as a prefix.

### Container requirements

The container must:

- Serve the **MCP Streamable HTTP** transport on `0.0.0.0:<port>`.
- Be **running** — stopped containers are skipped.
- Declare `{ "type": "network", "mode": "host" }` alongside the `mcp` entitlement (so the agent can reach the port over loopback).

See the [MCPExample](../Examples/MCPExample/README.md) for a complete Python reference implementation using `FastMCP` and `uvicorn`.

## gRPC API

### `StreamMCP`

```protobuf
rpc StreamMCP(stream MCPChunk) returns (stream MCPChunk);

message MCPChunk {
    bytes data = 1;
}
```

Bidirectional streaming RPC that proxies raw bytes between the caller and the container's MCP TCP port.

**Metadata (required):**

| Key | Value |
|-----|-------|
| `app-name` | The `appId` / container name of the target app |

**Error codes:**

| gRPC code | Meaning |
|-----------|---------|
| `InvalidArgument` | `app-name` metadata is missing or empty |
| `NotFound` | Container not found, or container has no `mcp` entitlement |
| `FailedPrecondition` | Container exists but is not in the `RUNNING` state |
| `Unavailable` | TCP connection to the container's MCP port failed |

### `AppContainer.mcp_port`

The `AppContainer` message returned by `ListContainers` now includes:

```protobuf
uint32 mcp_port = 5;
```

This field is `0` for containers without an `mcp` entitlement and non-zero for containers that declared one. Use it to determine which containers expose an MCP server.

## Client-side proxy (`mcp/proxy`)

`wendy mcp serve` uses an internal TCP proxy to bridge local MCP client connections through `StreamMCP`:

1. A local TCP listener is opened on an ephemeral port (`127.0.0.1:0`).
2. Each incoming TCP connection spawns a `StreamMCP` gRPC stream with the `app-name` metadata set.
3. Bytes are forwarded bidirectionally: TCP → gRPC chunks and gRPC chunks → TCP.
4. The proxy shuts down cleanly when the parent context is cancelled or when either side closes the connection.

This mechanism is transparent to the MCP client library (`mcp-go`), which sees a normal TCP endpoint.

## `wendyBinaryPath` resolution

When writing MCP server configuration files, `wendy mcp setup` resolves the binary path using `os.Executable()` without resolving symlinks. It falls back to a PATH lookup and finally to the literal string `"wendy"` if neither succeeds. This ensures the configuration records the stable symlink path (e.g. `/opt/homebrew/bin/wendy`) rather than a versioned real path, so the configuration remains valid across upgrades.
