# Wendy Agent gRPC API

The wendy-agent exposes a gRPC API that clients (the Wendy CLI, Wendy Cloud, and other tooling) use to manage apps, query device state, and stream telemetry. The API is defined in Protocol Buffer 3 and generated into Go.

Both **v1** and **v2** of the API are registered on the agent's gRPC server simultaneously. v1 is unchanged; v2 introduces focused, single-responsibility services in the `wendy.agent.services.v2` package.

---

## API Versions

| Package | Go package alias | Status |
|---------|-----------------|--------|
| `wendy.agent.services.v1` | `agentpbv1` | Stable, unchanged |
| `wendy.agent.services.v2` | `agentpbv2` | Current — see below |

---

## v1 Notes

### `RunContainerLayerHeader` (`wendy.agent.services.v1`)

The `RunContainerLayerHeader` message describes a single image layer sent to the agent during a `RunContainer` call.

| Field | Type | Description |
|-------|------|-------------|
| `digest` | `string` | Layer digest (e.g. `sha256:…`) |
| `size` | `int64` | Compressed layer size in bytes |
| `diff_id` | `string` | Uncompressed diff ID |
| `gzip` | `bool` | **Deprecated.** Whether the layer is gzip-compressed. Use `compression` instead. Kept for backward compatibility with older CLI versions that do not send `compression`. |
| `compression` | `CompressionType` | Compression format of the layer blob. When set to a non-zero value, takes precedence over `gzip`. |

#### `CompressionType` enum

| Value | Number | Description |
|-------|--------|-------------|
| `COMPRESSION_GZIP` | `0` | Default. Treated as gzip when `gzip=true`, uncompressed when `gzip=false`. |
| `COMPRESSION_ZSTD` | `1` | Zstandard-compressed layer. |
| `COMPRESSION_NONE` | `2` | Uncompressed layer. |

### `StartContainerRequest` (`wendy.agent.services.v1`)

| Field | Type | Description |
|-------|------|-------------|
| `app_name` | `string` | Name of the app to start. |
| `restart_policy` | `optional RestartPolicy` | Restart policy applied at start time. When unset, the agent reads the policy persisted as a containerd label during `CreateContainer` and uses that instead. |

When `restart_policy` is provided with a non-`NO` mode, the agent registers the container with the container monitor for automatic restart. When omitted, the persisted label is used for registration so that containers are correctly re-monitored after an agent restart. Explicitly setting `mode=NO` removes any existing monitor registration.

---

## v2 Services

All v2 proto files live under `Proto/wendy/agent/services/v2/`. Generated Go code is in `go/proto/gen/agentpb/v2/` (`go_package` = `github.com/wendylabsinc/wendy/proto/gen/agentpb/v2;agentpbv2`).

### Service overview

| Proto file | Service name | Description |
|-----------|-------------|-------------|
| `device_info_service.proto` | `WendyDeviceInfoService` | Device metadata and hardware capability enumeration |
| `agent_update_service.proto` | `WendyAgentUpdateService` | Agent binary self-update |
| `os_update_service.proto` | `WendyOSUpdateService` | OS-level update via Mender artifact URL |
| `wifi_service.proto` | `WendyWiFiService` | WiFi network management |
| `bluetooth_service.proto` | `WendyBluetoothService` | Bluetooth peripheral management |
| `container_service.proto` | `WendyContainerService` | Container lifecycle, volumes, and stats |
| `provisioning_service.proto` | `WendyProvisioningService` | Device provisioning and enrollment status |
| `audio_service.proto` | `WendyAudioService` | Audio device enumeration and streaming |
| `telemetry_service.proto` | `WendyTelemetryService` | OpenTelemetry log / metric / trace streaming |
| `file_sync_service.proto` | `WendyFileSyncService` | Bidirectional file sync |
| `shared.proto` | *(types only)* | Shared enums and messages used across services |

---

## Shared Types (`shared.proto`)

Shared types used by multiple v2 services.

### Enums

#### `RestartPolicyMode`

| Value | Number | Description |
|-------|--------|-------------|
| `RESTART_POLICY_MODE_UNSPECIFIED` | `0` | Unspecified |
| `RESTART_POLICY_MODE_UNLESS_STOPPED` | `1` | Restart unless manually stopped |
| `RESTART_POLICY_MODE_NO` | `2` | Never restart |
| `RESTART_POLICY_MODE_ON_FAILURE` | `3` | Restart on non-zero exit. **Note:** currently restarts on any exit (not only non-zero exits) because the monitor has no exit-code signal from containerd. `MaxRetries` is still enforced. |

#### `AppRunningState`

| Value | Number | Description |
|-------|--------|-------------|
| `APP_RUNNING_STATE_UNSPECIFIED` | `0` | Unspecified |
| `APP_RUNNING_STATE_STOPPED` | `1` | Container is stopped |
| `APP_RUNNING_STATE_RUNNING` | `2` | Container is running |

### Messages

#### `RestartPolicy`

| Field | Type | Description |
|-------|------|-------------|
| `mode` | `RestartPolicyMode` | Restart mode |
| `on_failure_max_retries` | `int32` | Maximum retries when `ON_FAILURE` mode is set. Negative values are clamped to zero. |

#### `AppContainer`

| Field | Type | Description |
|-------|------|-------------|
| `app_name` | `string` | App identifier |
| `app_version` | `string` | App version string |
| `running_state` | `AppRunningState` | Current running state |
| `failure_count` | `uint32` | Number of times the container has failed |

---

## `WendyDeviceInfoService`

Provides static device metadata and hardware capability enumeration.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `GetDeviceInfo` | `GetDeviceInfoRequest` | `GetDeviceInfoResponse` | Unary |
| `ListHardwareCapabilities` | `ListHardwareCapabilitiesRequest` | `ListHardwareCapabilitiesResponse` | Unary |

### `GetDeviceInfoResponse` fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | `string` | Agent version |
| `os_version` | `optional string` | OS version (e.g. WendyOS release) |
| `os` | `string` | OS name (e.g. `"linux"`) |
| `cpu_architecture` | `string` | CPU architecture (e.g. `"aarch64"`) |
| `public_key` | `optional string` | Device public key (PEM) |
| `featureset` | `repeated string` | Enabled feature flags |
| `device_type` | `optional string` | Hardware model identifier |
| `has_gpu` | `optional bool` | Whether a GPU is present |
| `gpu_vendor` | `optional string` | GPU vendor string |
| `jetpack_version` | `optional string` | NVIDIA JetPack version (Jetson only) |
| `cuda_version` | `optional string` | CUDA version (Jetson only) |

### `ListHardwareCapabilitiesRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `category_filter` | `optional string` | Filter by capability category (e.g. `"camera"`, `"gpio"`) |

### `HardwareCapability` fields

| Field | Type | Description |
|-------|------|-------------|
| `category` | `string` | Capability category |
| `device_path` | `string` | Device path (e.g. `/dev/video0`) |
| `description` | `string` | Human-readable description |
| `properties` | `map<string, string>` | Arbitrary key-value metadata |

---

## `WendyAgentUpdateService`

Streams a new agent binary to the device and triggers a self-replacement.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `UpdateAgent` | `stream UpdateAgentRequest` | `stream UpdateAgentResponse` | Bidirectional streaming |

### `UpdateAgentRequest` (`oneof request_type`)

| Field | Type | Description |
|-------|------|-------------|
| `chunk` | `Chunk` | Binary data chunk (`bytes data`) |
| `control` | `ControlCommand` | Control command |

#### `ControlCommand` (`oneof command`)

| Field | Type | Description |
|-------|------|-------------|
| `update` | `Update` | Trigger the update; `sha256` field is the hex-encoded SHA-256 of the full binary |

### `UpdateAgentResponse` (`oneof response_type`)

| Field | Type | Description |
|-------|------|-------------|
| `updated` | `Updated` | Emitted once the agent has successfully replaced itself |

---

## `WendyOSUpdateService`

Triggers an OS-level update using a Mender artifact.

Before invoking Mender, the agent checks whether the host is a WendyOS OTA target. If the host does not have a WendyOS identity (detected via `/etc/wendy/version.txt` or `/etc/wendyos/device-type`), `UpdateOS` immediately streams a `failed` response with the message `"This setup cannot be updated with wendy os update. Use this machine's normal OS update tools instead. To use WendyOS OTA updates, install WendyOS on supported hardware with wendy os install."` and does not invoke Mender. This applies to macOS agents, generic Linux hosts, and any other non-WendyOS platform.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `UpdateOS` | `UpdateOSRequest` | `stream UpdateOSResponse` | Server streaming |

### `UpdateOSRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `artifact_url` | `string` | URL of the Mender artifact to install |

### `UpdateOSResponse` (`oneof response_type`)

| Variant | Fields | Description |
|---------|--------|-------------|
| `progress` | `phase: string`, `percent: int32` | Update phase and percentage complete |
| `completed` | `reboot_required: bool` | Update finished; indicates whether a reboot is needed |
| `failed` | `error_message: string` | Update failed with the given error |

---

## `WendyWiFiService`

Manages WiFi connections on the device.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `ListWiFiNetworks` | `ListWiFiNetworksRequest` | `ListWiFiNetworksResponse` | Unary |
| `ConnectToWiFi` | `ConnectToWiFiRequest` | `ConnectToWiFiResponse` | Unary |
| `GetWiFiStatus` | `GetWiFiStatusRequest` | `GetWiFiStatusResponse` | Unary |
| `DisconnectWiFi` | `DisconnectWiFiRequest` | `DisconnectWiFiResponse` | Unary |
| `ListKnownWiFiNetworks` | `ListKnownWiFiNetworksRequest` | `ListKnownWiFiNetworksResponse` | Unary |
| `SetWiFiNetworkPriority` | `SetWiFiNetworkPriorityRequest` | `SetWiFiNetworkPriorityResponse` | Unary |
| `ReorderKnownWiFiNetworks` | `ReorderKnownWiFiNetworksRequest` | `ReorderKnownWiFiNetworksResponse` | Unary |
| `ForgetWiFiNetwork` | `ForgetWiFiNetworkRequest` | `ForgetWiFiNetworkResponse` | Unary |

### `WiFiSecurityType` enum

| Value | Number |
|-------|--------|
| `WIFI_SECURITY_TYPE_UNSPECIFIED` | `0` |
| `WIFI_SECURITY_TYPE_OPEN` | `1` |
| `WIFI_SECURITY_TYPE_WEP` | `2` |
| `WIFI_SECURITY_TYPE_WPA_PSK` | `3` |
| `WIFI_SECURITY_TYPE_WPA2_PSK` | `4` |
| `WIFI_SECURITY_TYPE_WPA3_SAE` | `5` |
| `WIFI_SECURITY_TYPE_WPA2_ENTERPRISE` | `6` |

### `ListWiFiNetworksResponse` — `WiFiNetwork` fields

| Field | Type | Description |
|-------|------|-------------|
| `ssid` | `string` | Network SSID |
| `signal_strength` | `optional int32` | Signal strength (0–100) |
| `security` | `WiFiSecurityType` | Security type |
| `is_known` | `bool` | Whether the device has a saved profile for this network |
| `is_connected` | `bool` | Whether currently connected |
| `priority` | `optional int32` | Autoconnect priority |
| `rssi_dbm` | `optional int32` | RSSI in dBm |

### `ConnectToWiFiRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `ssid` | `string` | Network SSID |
| `password` | `string` | Network password |
| `security` | `optional WiFiSecurityType` | Override security type |
| `hidden` | `optional bool` | Whether the network is hidden |

### `ListKnownWiFiNetworksResponse` — `KnownWiFiNetwork` fields

| Field | Type | Description |
|-------|------|-------------|
| `ssid` | `string` | Network SSID |
| `uuid` | `string` | NetworkManager connection UUID |
| `priority` | `int32` | Autoconnect priority |
| `security` | `WiFiSecurityType` | Security type |

### `ReorderKnownWiFiNetworksRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `order_ssids` | `repeated string` | SSIDs in desired priority order (highest first) |

---

## `WendyBluetoothService`

Manages Bluetooth peripheral discovery and connection.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `ScanBluetoothPeripherals` | `stream ScanBluetoothPeripheralsRequest` | `stream ScanBluetoothPeripheralsResponse` | Bidirectional streaming |
| `ConnectBluetoothPeripheral` | `ConnectBluetoothPeripheralRequest` | `ConnectBluetoothPeripheralResponse` | Unary |
| `DisconnectBluetoothPeripheral` | `DisconnectBluetoothPeripheralRequest` | `DisconnectBluetoothPeripheralResponse` | Unary |
| `ForgetBluetoothPeripheral` | `ForgetBluetoothPeripheralRequest` | `ForgetBluetoothPeripheralResponse` | Unary |

### `DiscoveredBluetoothPeripheral` fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Device display name |
| `address` | `string` | Bluetooth MAC address |
| `rssi` | `int32` | RSSI signal strength in dBm |
| `device_type` | `string` | Device type string (e.g. `"audio"`, `"input"`) |
| `paired` | `bool` | Whether the device is paired |
| `connected` | `bool` | Whether the device is currently connected |
| `trusted` | `bool` | Whether the device is trusted |

### `ConnectBluetoothPeripheralRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `address` | `string` | Bluetooth MAC address |
| `pair` | `bool` | Pair the device during connection |
| `trust` | `bool` | Trust the device during connection |

---

## `WendyContainerService`

Manages app container lifecycle, volumes, and resource stats.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `StartContainer` | `StartContainerRequest` | `stream ContainerStreamResponse` | Server streaming |
| `AttachContainer` | `stream AttachContainerRequest` | `stream ContainerStreamResponse` | Bidirectional streaming |
| `StopContainer` | `StopContainerRequest` | `StopContainerResponse` | Unary |
| `DeleteContainer` | `DeleteContainerRequest` | `DeleteContainerResponse` | Unary |
| `ListContainers` | `ListContainersRequest` | `stream ListContainersResponse` | Server streaming |
| `ListVolumes` | `ListVolumesRequest` | `ListVolumesResponse` | Unary |
| `RemoveVolume` | `RemoveVolumeRequest` | `RemoveVolumeResponse` | Unary |
| `ListContainerStats` | `ListContainerStatsRequest` | `ListContainerStatsResponse` | Unary |

### `StartContainerRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `app_name` | `string` | Name of the app to start. |
| `restart_policy` | `optional RestartPolicy` | Restart policy applied at start time. When unset, the agent reads the policy persisted as a containerd label during `CreateContainer` and uses that instead. Explicitly setting `mode=NO` removes any existing monitor registration. |

After a successful start, the agent clears any prior explicit-stop mark on the container so that automatic restarts are re-enabled.

### `StopContainer` behaviour

`StopContainer` marks the container as explicitly stopped in the monitor before issuing the containerd stop. This prevents the monitor from restarting the container in the window between the container exiting and the stop returning. If the stop call fails, the mark is cleared automatically so future automatic restarts are not suppressed.

### `DeleteContainer` behaviour

`DeleteContainer` marks the container as explicitly stopped and unregisters it from the monitor before issuing the containerd delete. If the delete subsequently fails, the container is left unregistered; the caller should retry deletion.

### `ContainerStreamResponse` (`oneof response_type`)

| Variant | Fields | Description |
|---------|--------|-------------|
| `started` | *(empty)* | Container has started |
| `stdout_output` | `data: bytes` | stdout bytes |
| `stderr_output` | `data: bytes` | stderr bytes |

### `AttachContainerRequest` (`oneof request_type`)

| Variant | Type | Description |
|---------|------|-------------|
| `app_name` | `string` | App to attach to (sent first) |
| `stdin_data` | `bytes` | stdin bytes forwarded to the container |

### `DeleteContainerRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `app_name` | `string` | App to delete |
| `delete_image` | `bool` | Also remove the container image |
| `delete_volumes` | `bool` | Also remove associated volumes |

### `ListContainersResponse` fields

| Field | Type | Description |
|-------|------|-------------|
| `container` | `AppContainer` | One container per streamed response message |

### `VolumeInfo` fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Volume name |
| `path` | `string` | Mount path on host |
| `size_bytes` | `int64` | Total size in bytes |
| `created_at` | `string` | RFC 3339 creation timestamp |
| `used_by` | `repeated string` | App names that reference this volume |

### `ContainerStats` fields

| Field | Type | Description |
|-------|------|-------------|
| `app_name` | `string` | App identifier |
| `memory_bytes` | `int64` | Current memory usage |
| `storage_bytes` | `int64` | Disk usage of container layers and volumes |

---

## `WendyProvisioningService`

Handles device provisioning and enrollment status checks.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `StartProvisioning` | `StartProvisioningRequest` | `StartProvisioningResponse` | Unary |
| `IsProvisioned` | `IsProvisionedRequest` | `IsProvisionedResponse` | Unary |

### `IsProvisionedResponse` (`oneof response_type`)

| Variant | Fields | Description |
|---------|--------|-------------|
| `not_provisioned` | *(empty)* | Device has not been provisioned |
| `provisioned` | `cloud_host: string`, `organization_id: int32`, `asset_id: int32` | Device is provisioned with the given cloud coordinates |

### `StartProvisioningRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `organization_id` | `int32` | Organisation to enroll the device into |
| `enrollment_token` | `string` | Token issued by pki-core / Wendy Cloud |
| `cloud_host` | `string` | Cloud gRPC endpoint (`host:port`) |
| `asset_id` | `int32` | Asset ID assigned to this device |

---

## `WendyAudioService`

Enumerates audio devices and streams audio data or level meters.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `ListAudioDevices` | `ListAudioDevicesRequest` | `ListAudioDevicesResponse` | Unary |
| `SetDefaultAudioDevice` | `SetDefaultAudioDeviceRequest` | `SetDefaultAudioDeviceResponse` | Unary |
| `StreamAudioLevels` | `StreamAudioLevelsRequest` | `stream AudioLevelUpdate` | Server streaming |
| `StreamAudio` | `StreamAudioRequest` | `stream AudioChunk` | Server streaming |

### `AudioDeviceType` enum

| Value | Number | Description |
|-------|--------|-------------|
| `AUDIO_DEVICE_TYPE_UNSPECIFIED` | `0` | Unspecified |
| `AUDIO_DEVICE_TYPE_INPUT` | `1` | Microphone / capture device |
| `AUDIO_DEVICE_TYPE_OUTPUT` | `2` | Speaker / playback device |

### `AudioDevice` fields

| Field | Type | Description |
|-------|------|-------------|
| `device_id` | `uint32` | Numeric device identifier |
| `name` | `string` | Short device name |
| `description` | `string` | Human-readable description |
| `type` | `AudioDeviceType` | Input or output |
| `is_default` | `bool` | Whether this is the system default device |

### `ListAudioDevicesRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `type_filter` | `optional AudioDeviceType` | Filter to only input or only output devices |

### `StreamAudioLevelsRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `device_id` | `uint32` | Device to monitor |
| `update_rate_hz` | `uint32` | Level meter update rate in Hz |

### `AudioLevelUpdate` fields

| Field | Type | Description |
|-------|------|-------------|
| `peak_db` | `float` | Peak level in dBFS |
| `rms_db` | `float` | RMS level in dBFS |
| `timestamp_ns` | `uint64` | Capture timestamp (nanoseconds since epoch) |

### `StreamAudioRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `device_id` | `uint32` | Device to capture from |
| `sample_rate` | `uint32` | Sample rate in Hz (e.g. `44100`, `48000`) |
| `channels` | `uint32` | Number of channels (e.g. `1` for mono, `2` for stereo) |

### `AudioChunk` fields

| Field | Type | Description |
|-------|------|-------------|
| `pcm_data` | `bytes` | Raw signed 16-bit little-endian PCM samples |
| `timestamp_ns` | `uint64` | Capture timestamp (nanoseconds since epoch) |
| `sample_rate` | `uint32` | Sample rate of this chunk |
| `channels` | `uint32` | Channel count of this chunk |

---

## `WendyTelemetryService`

Streams OpenTelemetry signals from the device to the client. Each response message wraps the standard OTLP collector request types.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `StreamLogs` | `StreamLogsRequest` | `stream StreamLogsResponse` | Server streaming |
| `StreamMetrics` | `StreamMetricsRequest` | `stream StreamMetricsResponse` | Server streaming |
| `StreamTraces` | `StreamTracesRequest` | `stream StreamTracesResponse` | Server streaming |

### `StreamLogsRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `service_name` | `optional string` | Filter by OTel service name |
| `min_severity` | `optional int32` | Minimum OTel severity number (e.g. `9` = INFO) |
| `app_name` | `optional string` | Filter by Wendy app name |

### `StreamLogsResponse` fields

| Field | Type | Description |
|-------|------|-------------|
| `logs` | `ExportLogsServiceRequest` | OTLP log export payload |

### `StreamMetricsRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `service_name` | `optional string` | Filter by OTel service name |
| `metric_name_prefix` | `optional string` | Filter metrics by name prefix |
| `app_name` | `optional string` | Filter by Wendy app name |

### `StreamMetricsResponse` fields

| Field | Type | Description |
|-------|------|-------------|
| `metrics` | `ExportMetricsServiceRequest` | OTLP metrics export payload |

### `StreamTracesRequest` fields

| Field | Type | Description |
|-------|------|-------------|
| `service_name` | `optional string` | Filter by OTel service name |
| `app_name` | `optional string` | Filter by Wendy app name |
| `span_name_prefix` | `optional string` | Filter spans by name prefix |

### `StreamTracesResponse` fields

| Field | Type | Description |
|-------|------|-------------|
| `traces` | `ExportTraceServiceRequest` | OTLP trace export payload |

> **Dependency:** `WendyTelemetryService` imports the standard OpenTelemetry collector proto types: `opentelemetry.proto.collector.logs.v1`, `opentelemetry.proto.collector.metrics.v1`, and `opentelemetry.proto.collector.trace.v1`.

---

## `WendyFileSyncService`

Bidirectional file sync between client and device. The client sends file manifests, chunks, commits, chmod commands, and delete instructions; the server responds with its own manifest (for diffing), per-file acknowledgements, and a final completion signal.

### RPCs

| Method | Request | Response | Type |
|--------|---------|----------|------|
| `SyncFiles` | `stream FileSyncRequest` | `stream FileSyncResponse` | Bidirectional streaming |

### `FileSyncRequest` (`oneof request_type`)

| Variant | Message | Description |
|---------|---------|-------------|
| `start` | `FileSyncStart` | Begin a sync session for `app_id`, includes client manifest |
| `chunk` | `FileSyncChunk` | A chunk of file data |
| `commit` | `FileSyncCommit` | Signals that all chunks for a file have been sent |
| `chmod` | `FileSyncChmod` | Change the mode of a file |
| `delete` | `FileSyncDelete` | Delete one or more paths |

### `FileSyncResponse` (`oneof response_type`)

| Variant | Message | Description |
|---------|---------|-------------|
| `manifest` | `FileSyncManifest` | Server-side file manifest returned after `start`, used for diffing |
| `ack` | `FileSyncAck` | Per-file acknowledgement (`path` field) |
| `complete` | `FileSyncComplete` | All operations have been applied |

### `FileSyncEntry` fields

| Field | Type | Description |
|-------|------|-------------|
| `path` | `string` | Relative file path |
| `size` | `int64` | File size in bytes |
| `sha256` | `bytes` | SHA-256 digest |
| `mode` | `uint32` | Unix file mode bits |

### `FileSyncChunk` fields

| Field | Type | Description |
|-------|------|-------------|
| `path` | `string` | Relative file path this chunk belongs to |
| `data` | `bytes` | Raw chunk bytes |
| `sequence` | `uint64` | Monotonically increasing chunk index |
| `cumulative_size` | `int64` | Total bytes sent so far for this file |
| `sha256` | `bytes` | SHA-256 of this chunk |

### `FileSyncChmod` fields

| Field | Type | Description |
|-------|------|-------------|
| `path` | `string` | File path |
| `mode` | `uint32` | New Unix mode bits |
| `size` | `int64` | File size (for verification) |
| `sha256` | `bytes` | File SHA-256 (for verification) |

### `FileSyncDelete` fields

| Field | Type | Description |
|-------|------|-------------|
| `paths` | `repeated string` | Paths to delete |

---

## Proto file locations

```
Proto/wendy/agent/services/v2/
  shared.proto
  device_info_service.proto
  agent_update_service.proto
  os_update_service.proto
  wifi_service.proto
  bluetooth_service.proto
  container_service.proto
  provisioning_service.proto
  audio_service.proto
  telemetry_service.proto
  file_sync_service.proto
```

Generated Go output: `go/proto/gen/agentpb/v2/`

---

## Connectivity

See [wendy-agent/connectivity/grpc.md](./connectivity/grpc.md) for transport details (ports, TLS, mTLS).
