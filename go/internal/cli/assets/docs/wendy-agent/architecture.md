# Wendy Agent Architecture

`wendy-agent` is a Go binary that runs on WendyOS devices and on DGX Spark. It exposes gRPC APIs consumed by the wendy CLI, manages containers through containerd, handles networking (WiFi / Bluetooth), streams OpenTelemetry telemetry, and connects devices to the Wendy Cloud.

## Command-line flags

Before the server starts, `wendy-agent` handles a small set of utility flags and exits:

| Flag | Description |
|------|-------------|
| `--version`, `-v` | Print the agent version string and exit. |

## Startup sequence

When `wendy-agent` starts it performs the following steps in order:

1. Initialises a `zap` production logger (development mode when `WENDY_DEBUG` is set). Agent logs are tee'd into the telemetry broadcaster so they can be streamed to CLI clients.
2. Reads config from `/etc/wendy-agent` (overrideable with `WENDY_CONFIG_PATH`).
3. Applies any pending config-partition overlay (`configpartition.Apply`).
4. Commits a pending Mender A/B update (`mender-update commit`) so Mender does not roll back on the next reboot.
5. Removes stale agent binary backups older than 48 hours.
6. Ensures the NVIDIA CDI spec exists for GPU container support.
7. Initialises subsystem managers:
   - **Network manager** – wraps `nmcli` for WiFi management (skipped when `nmcli` is absent).
   - **Hardware discoverer** – probes the system for GPU, audio, video, Bluetooth, I2C, GPIO, SPI, and USB devices.
   - **Bluetooth manager** – BlueZ-backed BLE/Bluetooth management.
   - **D-Bus proxy manager** – `xdg-dbus-proxy` sandbox for Bluetooth containers (falls back to unfiltered host D-Bus access when absent).
8. Connects to containerd (default socket, overrideable with `WENDY_CONTAINERD_ADDR`).
9. Constructs all gRPC service implementations (see below).
10. Starts the container monitor (polls containerd every 15 seconds; skipped when containerd is unavailable).
11. Starts background goroutines for container CPU/memory metrics and agent process metrics.
12. Decides which gRPC server(s) to start based on provisioning state (see [Security model](#security-model)).
13. Starts the embedded OCI registry (Linux only, best-effort).
14. Starts the OTEL gRPC and HTTP receivers.

## Component map

The following components are initialised in `go/cmd/wendy-agent/main.go`:

```
wendy-agent
├── gRPC servers
│   ├── Plaintext :50051      ← pre-provisioning only
│   ├── mTLS      :50052      ← post-provisioning (agentPort + 1)
│   └── OTEL gRPC :4317       ← always on
├── OTEL HTTP receiver :4318  ← always on
├── Embedded OCI registry :5000 ← Linux/containerd only
│
├── Services (registered on both plaintext and mTLS servers)
│   ├── WendyAgentService       – WiFi, Bluetooth, agent update, OS update, hardware
│   ├── WendyContainerService   – container lifecycle, layers, volumes, stats
│   ├── WendyAudioService       – audio device listing and streaming
│   ├── WendyVideoService       – video device listing and streaming
│   ├── WendyProvisioningService – device enrollment with Wendy Cloud
│   ├── WendyTelemetryService   – streaming OTLP logs, metrics, traces
│   └── WendyFileSyncService    – bidirectional file sync from CLI to containers
│
└── Internal subsystems
    ├── containerd client       – container creation, snapshots, image import
    ├── OCI entitlements        – GPU, audio, video, Bluetooth, USB, I2C, GPIO, SPI, persist
    ├── Container monitor       – watches running containers (15 s poll interval); wired into
    │                             ContainerService so restart policies take effect automatically
    ├── Container log manager   – multiplexes container stdout/stderr to telemetry broadcaster
    ├── Network manager (nmcli) – WiFi scan, connect, disconnect, priorities
    ├── Bluetooth manager (BlueZ) – BLE peripheral advertising, device pairing
    ├── D-Bus proxy manager     – xdg-dbus-proxy sandboxing for Bluetooth containers
    ├── Tunnel broker client    – persistent gRPC presence stream to Wendy Cloud
    ├── Telemetry broadcaster   – fan-out for OTLP logs/metrics/traces
    ├── CDI (NVIDIA)            – ensures nvidia CDI spec for GPU containers
    └── Config partition        – applies overlay from /etc/wendy-agent
```

## Container restart policies

When a container is started or attached with a non-`NO` restart policy, `ContainerService` registers it with the container monitor. The monitor polls containerd every 15 seconds and restarts any registered container that is no longer running, subject to the policy rules below.

| Policy | Restart behaviour |
|--------|------------------|
| `UNLESS_STOPPED` | Restarts on any exit unless the container was explicitly stopped via `StopContainer`. |
| `ON_FAILURE` | Currently behaves identically to `UNLESS_STOPPED`: restarts on any exit (not only non-zero exits) because containerd does not yet provide an exit-code signal to the monitor. `MaxRetries` is still enforced. |
| `NO` | Never restarted. Clears any existing monitor registration. |

`StopContainer` marks the container as explicitly stopped in the monitor *before* issuing the containerd stop, preventing the monitor from restarting it in the window between the container exiting and the stop call returning. If the stop call fails, the mark is cleared so future automatic restarts are not suppressed.

`StartContainer` and `AttachContainer` clear any prior explicit-stop mark as soon as the container starts successfully, re-enabling automatic restarts.

When `StartContainer` is called without a restart policy, the agent reads the policy persisted as a containerd label during `CreateContainer` and uses that for monitor registration. This ensures containers are correctly re-registered after an agent restart without requiring the client to resupply the policy.

## Security model

The agent uses two separate gRPC listeners to enforce the provisioning boundary:

| Listener | Port | TLS | Purpose |
|---|---|---|---|
| Plaintext | `50051` (default) | None | Pre-provisioning only. Shut down automatically once the device enrolls. |
| mTLS | `50052` (default, agentPort + 1) | Mutual TLS with device certificate | Post-provisioning. All seven services are registered here. |
| OTEL gRPC | `4317` | None | OpenTelemetry collector endpoint for container workloads. Localhost only. Always on. |
| OTEL HTTP | `4318` | None | OTLP/HTTP endpoint (protobuf and JSON). Localhost only. Always on. |
| OCI Registry | `5000` | HTTP pre-provisioning, HTTPS post-provisioning | Development container image push target. |

When `StartProvisioning` completes successfully, the agent:

1. Starts the mTLS server on `agentPort + 1`.
2. Gracefully stops the plaintext server.
3. Restarts the embedded OCI registry with HTTPS using the device certificate.
4. Starts advertising the device via Avahi mDNS using the mTLS port.
5. Starts BLE advertising and the mTLS-protected L2CAP server.
6. Connects to the Wendy Cloud tunnel broker.

Provisioning state (certificates, org/asset IDs) is persisted to `/etc/wendy-agent/provisioning.json` (mode `0600`). Individual PEM files are written alongside it for services that read certificates from the filesystem.

## Port summary

| Port | Protocol | Service |
|---|---|---|
| `50051` | gRPC (plaintext) | Agent API – pre-provisioning |
| `50052` | gRPC (mTLS) | Agent API – post-provisioning |
| `4317` | gRPC | OTLP log/metric/trace receiver (localhost only) |
| `4318` | HTTP | OTLP/HTTP receiver (localhost only) |
| `5000` | HTTP or HTTPS | Embedded OCI registry |

All ports can be overridden with environment variables (`WENDY_AGENT_PORT`, `WENDY_OTEL_PORT`, `WENDY_OTEL_HTTP_PORT`, `WENDY_REGISTRY_ADDR`).

## Cloud connectivity

After provisioning, the tunnel broker client (`services.TunnelBrokerClient`) opens a `RegisterPresence` streaming RPC to the Wendy Cloud broker. The broker URL defaults to `<cloudHost>:50052`; when the cloud host uses port `443` the same address is used directly. The client reconnects with exponential backoff (1 s – 5 min) on failure.

### TLS trust model for broker connections

Both the agent's tunnel broker client and the CLI's `dialCloudBroker` function build their TLS CA pool by starting from the **system certificate pool** and then optionally appending the stored Wendy CA chain:

- **Agent (`TunnelBrokerClient`):** Seeds the CA pool from the OS system cert pool (falling back to an empty pool if the system pool is unavailable), then appends the Wendy CA chain from `chainPEM` when it is non-empty. Hostname verification is skipped because the broker certificate CN is `localhost`; full chain validation against the combined pool is still performed.

- **CLI (`dialCloudBroker`):** The trust strategy depends on the broker URL:
  - **Port `:443` (Wendy Cloud):** Standard TLS is used. The system certificate pool is trusted as-is, allowing public CA-signed broker certificates to be verified normally without any custom validation hook.
  - **Non-`:443` ports (local or on-premises brokers):** The server presents a certificate signed by the Wendy CA. Hostname verification is skipped and a `VerifyConnection` hook validates the chain against the stored Wendy CA bundle (`PemCertificateChain`). If the CA bundle contains no valid certificates, the connection fails.

## mDNS advertisement

On provisioned devices the agent uses Avahi to advertise `_wendyos._udp` on the mTLS port. Pre-provisioning, the Avahi service file advertises port `50051`. The CLI discovers local devices via this mDNS service type.

## OCI entitlements

Container specs are built by the agent via the `oci` package (`go/internal/agent/oci/`). The `ApplyEntitlements` function maps `wendy.json` entitlement declarations to OCI spec modifications:

| Entitlement | Effect |
|---|---|
| `gpu` | Mounts NVIDIA CDI devices, adds NVIDIA capabilities |
| `network` | Sets network mode (`host` or `none`) |
| `audio` | Bind-mounts `/dev/snd`, adds audio group (GID 29) |
| `video` / `camera` | Bind-mounts V4L2 devices, adds video group (GID 44) |
| `bluetooth` | Mounts filtered D-Bus socket (via `xdg-dbus-proxy`) or raw host socket |
| `usb` | Bind-mounts `/dev/bus/usb` |
| `i2c` | Bind-mounts specified I2C device |
| `gpio` | Bind-mounts specified GPIO device |
| `spi` | Bind-mounts SPI devices |
| `persist` | Mounts named volume from `/var/lib/wendy/volumes/` |
| `input` | Bind-mounts `/dev/input/`, adds input group (GID 105) |
