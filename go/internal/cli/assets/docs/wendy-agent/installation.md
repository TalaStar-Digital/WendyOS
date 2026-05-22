# Installing Wendy Agent

`wendy-agent` runs on Linux (amd64 and arm64). The recommended installation method depends on what package manager is available on the target system.

## Quick install (any Linux)

The install script automatically detects the package manager and installs via the appropriate method:

```sh
curl -fsSL https://wendy.sh/install-agent | bash
```

Or download the script directly from the `wendy-agent` repository (`docs/agent.sh`) and inspect it before running.

The script installs `wendy-agent` if it is not already present, or upgrades it if it is.

## Package managers

### Debian / Ubuntu (APT)

The script adds the Wendy APT repository hosted on Google Artifact Registry:

```sh
sudo apt-get install -y ca-certificates curl gnupg
sudo mkdir -p /usr/share/keyrings
curl -fsSL https://us-central1-apt.pkg.dev/doc/repo-signing-key.gpg \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/wendy-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/wendy-archive-keyring.gpg] \
  https://us-central1-apt.pkg.dev/projects/cloud-c7e56 wendy-apt main" \
  | sudo tee /etc/apt/sources.list.d/wendy.list
sudo apt-get update
# Install if not present, or upgrade if already installed:
if dpkg-query -W -f='${Status}' wendy-agent 2>/dev/null | grep -q "install ok installed"; then
  sudo apt-get install -y --only-upgrade wendy-agent
else
  sudo apt-get install -y wendy-agent
fi
```

To install a pre-built `.deb` directly:

```sh
sudo apt install ./wendy-agent_<version>_<arch>.deb
```

### Fedora / RHEL (DNF or YUM)

```sh
sudo tee /etc/yum.repos.d/wendy.repo <<'EOF'
[wendy]
name=Wendy Repository
baseurl=https://us-central1-yum.pkg.dev/projects/cloud-c7e56/wendy-yum
enabled=1
gpgcheck=0
EOF
sudo dnf makecache --refresh
# Install if not present, or upgrade if already installed:
if rpm -q wendy-agent &>/dev/null; then
  sudo dnf upgrade -y wendy-agent
else
  sudo dnf install -y wendy-agent
fi
```

Or install a pre-built `.rpm` directly:

```sh
sudo dnf install ./wendy-agent-<version>.<arch>.rpm
```

### Arch Linux (AUR)

```sh
yay -S wendy-agent
# or
paru -S wendy-agent
```

## GitHub Releases (binary tarball)

Pre-built tarballs for `linux/amd64` and `linux/arm64` are published to GitHub Releases at:

```
https://github.com/wendylabsinc/wendy-agent/releases
```

Asset naming convention:

```
wendy-agent-linux-<arch>-<version>.tar.gz
```

Example for version `v0.5.0` on arm64:

```
wendy-agent-linux-arm64-0.5.0.tar.gz
```

### Manual installation from a tarball

```sh
VERSION=v0.5.0
ARCH=arm64   # or amd64

curl -fsSL \
  "https://github.com/wendylabsinc/wendy-agent/releases/download/${VERSION}/wendy-agent-linux-${ARCH}-${VERSION#v}.tar.gz" \
  -o wendy-agent.tar.gz

tar -xzf wendy-agent.tar.gz
sudo install -m 755 "wendy-agent-linux-${ARCH}/wendy-agent" /usr/local/bin/wendy-agent
```

### Checksum verification

SHA-256 verification is performed automatically when the CLI uses `wendy device update`. The CLI computes `sha256.Sum256` over the binary data and sends the hash to the agent's `UpdateAgent` RPC, which rejects the update if the hashes do not match.

For manual verification, compute the SHA-256 of the downloaded tarball and compare it against the expected hash published in the release notes or CI artifacts:

```sh
sha256sum wendy-agent-linux-${ARCH}-${VERSION#v}.tar.gz
```

## Service configuration

The install script and package post-install hooks create the following layout (package installs use `/usr/bin/wendy-agent`; tarball installs use `/usr/local/bin/wendy-agent` — update the `ExecStart` path in the unit if installing manually):

| Path | Description |
|---|---|
| `/usr/bin/wendy-agent` | Agent binary (package install; `/usr/local/bin/wendy-agent` for tarball) |
| `/usr/lib/systemd/system/wendy-agent.service` | systemd unit |
| `/etc/default/wendy-agent` | Environment file (sourced by the unit) |
| `/etc/wendy-agent/config.json` | Placeholder JSON config (`{}`) |
| `/var/lib/wendy-agent/` | Working directory (container state, etc.) |
| `/etc/wendy-agent/provisioning.json` | Provisioning state (written after enrollment) |
| `/etc/wendy-agent/device-key.pem` | Device private key (written after first provisioning) |

### systemd unit

```ini
[Unit]
Description=Wendy Agent
After=network-online.target dbus.service containerd.service
Wants=network-online.target containerd.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/wendy-agent
WorkingDirectory=/var/lib/wendy-agent
ExecStart=/usr/bin/wendy-agent
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

The unit uses `Wants=containerd.service`. If containerd is absent the agent starts anyway with container features disabled (a warning is logged).

### Environment file (`/etc/default/wendy-agent`)

```sh
# Cgroup parent used for container workloads.
WENDY_SYSTEMD_SERVICE_NAME=wendy-agent

# Network manager selection options:
# auto, connman, networkmanager, force-connman, force-networkmanager
# WENDY_NETWORK_MANAGER=auto
```

Additional overrides recognised by the agent:

| Variable | Default | Description |
|---|---|---|
| `WENDY_CONFIG_PATH` | `/etc/wendy-agent` | Directory for provisioning state and certificates. |
| `WENDY_AGENT_PORT` | `50051` | Plaintext gRPC port (pre-provisioning). mTLS port = this + 1. |
| `WENDY_OTEL_PORT` | `4317` | OTLP gRPC receiver port. |
| `WENDY_OTEL_HTTP_PORT` | `4318` | OTLP HTTP receiver port. |
| `WENDY_CONTAINERD_ADDR` | containerd default socket | Containerd socket path. |
| `WENDY_REGISTRY_ADDR` | `0.0.0.0:5000` | Embedded OCI registry listen address. |
| `WENDY_BROKER_URL` | derived from cloud host | Override the Wendy Cloud tunnel broker URL. |
| `WENDY_DEBUG` | unset | Set to any non-empty value to enable development-mode logging. |

### Managing the service

```sh
# Enable and start on boot
sudo systemctl enable --now wendy-agent

# Check status
sudo systemctl status wendy-agent

# View logs
sudo journalctl -u wendy-agent -f

# Restart after config changes
sudo systemctl restart wendy-agent
```

## mDNS advertisement

When Avahi is installed, the agent is advertised as `_wendyos._udp` on the local network. The Avahi service file is placed at `/etc/avahi/services/wendy-agent.service` during installation. The post-install hook restarts `avahi-daemon` to pick it up immediately.

The advertised port updates automatically when the device is provisioned: it switches from the plaintext port (`50051`) to the mTLS port (`50052`).

## Runtime dependencies

| Dependency | Required | Purpose |
|---|---|---|
| `containerd` | Required for containers | Container runtime |
| `dbus` | Required | D-Bus socket for Bluetooth and D-Bus proxy |
| `systemd` | Required | Service management and cgroup integration |
| `xdg-dbus-proxy` | Recommended | Filtered D-Bus access for Bluetooth containers |
| `networkmanager` (nmcli) | Optional | WiFi management |
| `connman` | Optional | WiFi management (alternative to NetworkManager) |
| `bluez` | Optional | Bluetooth support |
| `avahi-daemon` | Optional | mDNS device discovery |
| `mender-update` or `mender` | Optional | OTA OS updates |
