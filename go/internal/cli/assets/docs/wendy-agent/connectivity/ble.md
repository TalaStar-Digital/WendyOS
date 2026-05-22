# BLE Connectivity

The Wendy CLI uses Bluetooth Low Energy for two distinct purposes:

1. **Device discovery** — BLE advertisements allow the CLI to find nearby devices (alongside mDNS). Used by `wendy discover` and the device-selection picker.
2. **Command transport** — once connected, BLE is a full command channel. WendyOS agents expose a rich gRPC-like command protocol over BLE L2CAP. Wendy Lite devices expose a lighter GATT provisioning interface.

---

## Device Discovery

`wendy discover` and the interactive device picker both scan BLE and mDNS in parallel. BLE advertisements broadcast the device name and — for WendyOS devices — the L2CAP PSM needed to open a command channel. The picker renders all discovered devices with their available transports (BLE, LAN, Ethernet, …).

See also: [mDNS service discovery](../../wendyos/networking/mdns.md), [device selection](../../clients/wendy-cli/device-selection.md).

---

## WendyOS Agent: L2CAP + mTLS Command Transport

WendyOS devices expose a command channel over BLE using a CoC (Connection-Oriented Channel) on L2CAP PSM 128 (default). The PSM can be overridden via the `L2CAPPSM` field in the discovered device record.

### Connection sequence

```
CLI                                Device (wendy-agent)
 │                                       │
 │──── BLE connect ──────────────────────▶│
 │◀─── connected ────────────────────────│
 │                                       │
 │──── OpenL2CAP(PSM=128) ───────────────▶│
 │◀─── L2CAP channel open ───────────────│
 │                                       │
 │──── TLS ClientHello ──────────────────▶│  (mTLS over L2CAP)
 │◀─── TLS ServerHello + cert ───────────│
 │──── TLS cert + Finished ─────────────▶│
 │◀─── TLS Finished ─────────────────────│
 │                                       │
 │  (TLS tunnel established)             │
 │──── [UInt16 BE len][protobuf cmd] ────▶│
 │◀─── [UInt16 BE len][protobuf resp] ───│
```

The TLS client uses a certificate issued by the same PKI as the agent's server certificate. The agent's server certificate is self-signed (not issued by a public CA), so the client sets `InsecureSkipVerify: true` — this is intentional; trust is established through the PKI chain, not the CA store.

### Message framing

Each message is a 2-byte big-endian length prefix followed by a protobuf payload. Both directions use the same framing. The protobuf types are `BluetoothCommand` (client→agent) and `BluetoothResponse` (agent→client), defined in the v1 proto package (`wendy.agent.services.v1`).

### Available commands

| Command | Description |
|---------|-------------|
| `WifiConnect` | Connect to a WiFi network (SSID, password, optional security type and hidden flag) |
| `WifiList` | List visible WiFi networks |
| `WifiStatus` | Get current WiFi connection status |
| `WifiDisconnect` | Disconnect from the current WiFi network |
| `WifiKnownList` | List saved WiFi profiles |
| `WifiSetPriority` | Set autoconnect priority for a saved network by SSID |
| `WifiReorder` | Reorder saved networks by SSID |
| `WifiForget` | Remove a saved WiFi profile by SSID |
| `AgentVersion` | Get agent version and device info |
| `AppsList` | List deployed apps |
| `AppsStop` | Stop an app by name |
| `AppsRemove` | Remove an app by name (optionally purge image) |
| `HardwareList` | Enumerate hardware capabilities |

All commands receive a `BluetoothResponse` in return. Error responses carry an `error` variant with a `message` string; the CLI surfaces this as a Go `error`.

### Platform implementation

The `Connection` type in `go/internal/cli/ble/` wraps platform-specific BLE APIs:

| Platform | Backend |
|----------|---------|
| macOS | CoreBluetooth via CGo (`ble_darwin.go` + `ble_darwin.h`) |
| Linux | BlueZ (DBus via `ble_linux.go`) |
| Windows | WinRT Bluetooth (`ble_windows.go`) |

The public API (`Connect`, `OpenL2CAP`, `L2CAPSend`, `L2CAPRecv`, `Close`, etc.) is identical across platforms. The `AgentClient` type in `agent_client.go` is platform-independent and uses only this API.

---

## Wendy Lite (ESP32): GATT WiFi Provisioning

Wendy Lite devices do not run wendy-agent. Before a device is on WiFi, the only way to reach it is BLE. The CLI (and the `tools/ble_provision.py` script) use a simple GATT service for WiFi provisioning.

### GATT service

**Service UUID:** `4E57454E-4459-0001-0000-000000000000` ("NWENDY" + service 0001)

| Characteristic | UUID | Operation | Description |
|----------------|------|-----------|-------------|
| SSID | `4E57454E-4459-0001-0001-000000000000` | Write | Target WiFi SSID |
| Password | `4E57454E-4459-0001-0002-000000000000` | Write | WiFi password |
| Command | `4E57454E-4459-0001-0003-000000000000` | Write | Control byte: `0x01` = connect, `0x02` = clear credentials |
| Status | `4E57454E-4459-0001-0004-000000000000` | Read / Notify | Connection status (see below) |
| Device Name | `4E57454E-4459-0001-0005-000000000000` | Read | Device display name (e.g. `Wendy-A3F2`) |

### Status characteristic encoding

The status characteristic returns one or more bytes:

| Byte 0 | Meaning |
|--------|---------|
| `0x00` | No credentials stored |
| `0x01` | Connecting |
| `0x02` | Connected — bytes 1..n are the IP address (UTF-8) |
| `0x03` | Failed |

### WiFi provisioning protocol

```
CLI / tool                          Wendy Lite device
    │                                       │
    │──── Write SSID ───────────────────────▶│
    │──── Write password ───────────────────▶│
    │──── Subscribe to Status ──────────────▶│
    │──── Write Command = 0x01 (connect) ───▶│
    │                                       │
    │◀─── Status notify: 0x01 (connecting) ─│  (may repeat)
    │◀─── Status notify: 0x02 + IP ─────────│  (success)
    │             — or —                    │
    │◀─── Status notify: 0x03 (failed) ─────│
```

The CLI waits up to 30 seconds for a terminal status notification. If notifications time out, it falls back to reading the status characteristic directly. The Python provisioning script (`tools/ble_provision.py`) follows the same protocol using the `bleak` library.

### CLI usage

WiFi provisioning for a Wendy Lite device is done through `wendy device setup` (interactive wizard) or by using the Python script directly:

```bash
# Scan for nearby Wendy devices
python3 tools/ble_provision.py scan

# Provision WiFi credentials
python3 tools/ble_provision.py provision Wendy-A3F2 --ssid MyNetwork --password secret

# Clear stored credentials
python3 tools/ble_provision.py clear Wendy-A3F2
```

After successful WiFi provisioning, the device connects to the network and begins advertising via mDNS. The CLI can then reach it over WiFi using the standard gRPC transport.

---

## After WiFi: LAN gRPC

Once a device (WendyOS or Wendy Lite) is on WiFi, the CLI prefers the LAN gRPC transport over BLE for all subsequent operations. BLE remains available as a fallback when WiFi is not reachable.

Transport selection priority (per [device selection](../../clients/wendy-cli/device-selection.md)):

1. `--device <ip>` — direct gRPC over LAN/Ethernet
2. Default device (if set and reachable) — gRPC
3. mDNS + BLE discovery picker — gRPC if device is on WiFi, BLE otherwise

See [grpc.md](./grpc.md) for details on the gRPC transport, ports, and mTLS.
