# Wendy Agent Auto-Update

`wendy-agent` supports two update mechanisms:

1. **CLI-initiated agent binary update** – the `wendy device update` CLI command downloads a new binary from GitHub and streams it to the running agent over gRPC.
2. **OS-level update via Mender** – the `wendy os update` command instructs the agent to run `mender-update install` with a Mender artifact URL.

There is no built-in automatic timer inside the agent binary itself. Auto-update scheduling (if desired) is done externally via a systemd timer or a cron job that invokes `wendy device update`.

---

## CLI-initiated agent update

### How it works

The `wendy device update` command (`go/internal/cli/commands/device.go: newDeviceUpdateCmd`) performs the following steps:

1. Connects to the target device.
2. Queries `GetAgentVersion` to determine the device CPU architecture (`amd64` or `arm64`).
3. Fetches the latest (or nightly) release from the GitHub API:
   - Stable: `GET https://api.github.com/repos/wendylabsinc/wendy-agent/releases/latest`
   - Nightly: `GET https://api.github.com/repos/wendylabsinc/wendy-agent/releases` (first pre-release)
4. Downloads the matching tarball asset (`wendy-agent-linux-<arch>-<version>.tar.gz`) and extracts the binary.
5. Computes `sha256.Sum256` over the binary.
6. Opens the `UpdateAgent` bidirectional stream and sends the binary in 64 KiB chunks followed by a control message containing the SHA-256 hash.
7. If `--binary <path>` is given, steps 2–4 are skipped and the local file is used instead. The CLI still validates the ELF architecture against the device.

### Agent-side update handling (`UpdateAgent` RPC)

The agent's `UpdateAgent` handler (`go/internal/agent/services/agent_service.go`):

1. Acquires an exclusive update lock (one update at a time).
2. Accumulates incoming chunks and computes a running SHA-256.
3. On receiving the control message, compares the computed hash against the expected hash. Returns `codes.DataLoss` on mismatch.
4. Resolves the current executable path (following symlinks).
5. Writes the new binary to `<execPath>.update`.
6. Renames `<execPath>` to `<execPath>.backup`.
7. Atomically renames `<execPath>.update` to `<execPath>`.
8. Sends the `Updated` response.
9. Calls `os.Exit(0)` after a 500 ms delay.

systemd restarts the agent immediately because the unit has `Restart=always` with `RestartSec=2`.

On the next startup, `CommitMenderUpdate` runs `mender-update commit` to confirm the update if the device uses Mender A/B. `CleanupOldBackups` removes `<execPath>.backup` files older than 48 hours.

### Rollback

If the atomic rename fails, the backup is restored automatically. A manual rollback is also possible during the 48-hour backup retention window:

```sh
# On the device:
sudo cp /usr/bin/wendy-agent.backup /usr/bin/wendy-agent
sudo systemctl restart wendy-agent
```

### Usage

```sh
# Update to latest stable release
wendy device update

# Update to latest nightly (pre-release)
wendy device update --nightly

# Update from a local binary (useful for air-gapped devices)
wendy device update --binary ./wendy-agent-linux-arm64
```

---

## CLI update check

The CLI (`wendy`) checks GitHub for newer CLI releases once every 24 hours. The check runs in a background goroutine after each command. If a newer version is found, a notice is printed after the command completes:

```
Update available: v0.6.0 (you have v0.5.0)
Update with: wendy device update
```

The last-check timestamp is stored in the CLI config file. Dev builds (`version == "dev"`) skip the check entirely.

---

## Setting up a systemd timer for automatic agent updates

There is no timer shipped in the default packaging. To set one up:

### Create the service unit

```ini
# /etc/systemd/system/wendy-agent-update.service
[Unit]
Description=Wendy Agent automatic update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Replace <device-address> with the target device IP or hostname.
ExecStart=/usr/bin/wendy --device <device-address> device update
```

### Create the timer unit

```ini
# /etc/systemd/system/wendy-agent-update.timer
[Unit]
Description=Run Wendy Agent update check daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

### Enable the timer

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now wendy-agent-update.timer

# Check status
systemctl status wendy-agent-update.timer
systemctl list-timers wendy-agent-update*
```

### Disable auto-updates

```sh
sudo systemctl disable --now wendy-agent-update.timer
```

---

## OS-level update (Mender)

The `UpdateOS` RPC accepts a Mender artifact URL, runs `mender-update install <url>`, streams progress, and reboots on completion. The CLI exposes this via `wendy os update`.

Before running Mender, the agent checks whether the host is a WendyOS OTA target. The check reads `/etc/wendy/version.txt` (older WendyOS builds) and falls back to checking for `/etc/wendyos/device-type` (newer images). If neither marker is present, `UpdateOS` immediately returns a failure response without invoking Mender. Generic Linux hosts with `wendy-agent` installed but no WendyOS identity markers are rejected by this check.

The agent detects the `mender-update` (or legacy `mender`) binary at startup by searching standard `PATH` locations. When found, `mender` appears in the `featureset` field of `GetAgentVersionResponse`.

On NVIDIA Jetson devices, the agent calls `nvbootctrl` to enable rootfs A/B redundancy before running Mender if it is not already enabled.
