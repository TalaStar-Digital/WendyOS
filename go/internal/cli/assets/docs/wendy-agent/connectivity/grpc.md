Wendy-Agent exposes a gRPC endpoint, which [clients](../../clients/) can connect to to control the device.

Common operations include:
- Starting/Stopping apps
- [Reading telemetry](../otel.md)
- Setting up WiFi
- [Enrolling a device](../../pki/) (with cert)
- [macOS](../macos/) or [Linux](../linux/) specific operations

> **TODO (urgent)**: Each of these operation types **should** be exposed as a separate gRPC service
> Agents that cannot support a service, for example, if a device does not have WiFi, can omit the service.
> Clients can then detect the lack of a service through gRPC reflection.

## Keepalive

Both the plaintext and mTLS gRPC servers, as well as all gRPC clients, use keepalive to detect and recover from stale connections (common on mobile networks and across NAT).

**Server policy:**

| Parameter | Value |
|-----------|-------|
| Minimum client ping interval (`MinTime`) | 5 s |
| Pings permitted without active streams | yes |
| Server-initiated ping interval (`Time`) | 30 s |
| Ping timeout (`Timeout`) | 10 s |

**Client parameters:**

| Parameter | Value |
|-----------|-------|
| Client ping interval (`Time`) | 30 s |
| Ping timeout (`Timeout`) | 10 s |
| Pings permitted without active streams | yes |
