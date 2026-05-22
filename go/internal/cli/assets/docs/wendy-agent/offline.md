# Offline Installation

This page covers installing `wendy-agent` and related components on devices that do not have internet access, and working with air-gapped container images.

---

## Offline agent binary installation

When the device has no package manager and no internet access, download the release tarball on a connected machine and transfer it to the device.

### 1. Download on a connected machine

```sh
VERSION=v0.5.0
ARCH=arm64   # or amd64

curl -fsSL \
  "https://github.com/wendylabsinc/wendy-agent/releases/download/${VERSION}/wendy-agent-linux-${ARCH}-${VERSION#v}.tar.gz" \
  -o "wendy-agent-linux-${ARCH}.tar.gz"
```

### 2. Transfer to the device

```sh
scp "wendy-agent-linux-${ARCH}.tar.gz" user@device:/tmp/
```

### 3. Extract and install on the device

```sh
cd /tmp
tar -xzf wendy-agent-linux-${ARCH}.tar.gz
sudo install -m 755 wendy-agent-linux-${ARCH}/wendy-agent /usr/local/bin/wendy-agent
```

### 4. Set up the systemd service manually

```sh
sudo mkdir -p /var/lib/wendy-agent/storage /etc/wendy-agent

sudo tee /usr/lib/systemd/system/wendy-agent.service <<'EOF'
[Unit]
Description=Wendy Agent
After=network-online.target dbus.service containerd.service
Wants=network-online.target containerd.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/wendy-agent
WorkingDirectory=/var/lib/wendy-agent
ExecStart=/usr/local/bin/wendy-agent
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p /etc/default
sudo tee /etc/default/wendy-agent <<'EOF'
WENDY_SYSTEMD_SERVICE_NAME=wendy-agent
# WENDY_NETWORK_MANAGER=auto
EOF

printf "{}\n" | sudo tee /etc/wendy-agent/config.json > /dev/null
sudo chmod 600 /etc/wendy-agent/config.json

sudo systemctl daemon-reload
sudo systemctl enable --now wendy-agent
```

---

## Offline dev container registry

The embedded OCI registry (`localhost:5000`) is built into `wendy-agent` and backed by containerd. It requires no separate installation and allows the CLI to push container images directly to the device.

For WendyOS devices or devices provisioned offline, a pre-bundled OCI tar archive can be imported into containerd on first boot via the `wendyos-dev-registry-import.service` unit.

### Pre-bundled registry image

The archive lives at:

```
/usr/share/wendyos/offline-images/containerd-registry.tar
```

The import service runs once and skips re-runs using a sentinel file:

```ini
ConditionPathExists=!/var/lib/wendyos/dev-registry-imported
ConditionPathExists=/usr/share/wendyos/offline-images/containerd-registry.tar
```

After a successful import, `/var/lib/wendyos/dev-registry-imported` is created. Delete this file to force re-import on the next boot.

### Manual import

```sh
sudo ctr -n default images import /usr/share/wendyos/offline-images/containerd-registry.tar
```

---

## Pre-pulling application images

For air-gapped deployments, OCI images must be pre-imported into containerd before the device loses network access.

### Workflow

**On a connected machine:**

```sh
docker build -t myapp:latest .
docker save myapp:latest -o myapp.tar
```

**Transfer to the device:**

```sh
scp myapp.tar user@device:/tmp/
```

**Import into containerd on the device:**

```sh
sudo ctr -n default images import /tmp/myapp.tar
```

If the device is connected over USB, you can also use `wendy run` to deploy the application directly without manually transferring and importing the image first.

### Layer deduplication

When the CLI deploys an app it calls `ListLayers` first to see which OCI layer digests containerd already holds, and skips uploading layers that are already present. Pre-importing images means only new or changed layers need to be transferred on subsequent deployments.

---

## Air-gapped agent updates

When the device has no internet access, use `wendy device update --binary` with a locally downloaded binary:

```sh
# On a connected machine: download for the device architecture
curl -fsSL \
  "https://github.com/wendylabsinc/wendy-agent/releases/download/v0.5.0/wendy-agent-linux-arm64-0.5.0.tar.gz" \
  | tar -xz --strip-components=1 wendy-agent-linux-arm64/wendy-agent

# Push to the device
wendy --device <device-ip> device update --binary ./wendy-agent
```

The CLI computes the SHA-256 of the binary and sends it with the update command; the agent verifies it before replacing itself.

---

## Persistent volumes and offline storage

Persistent volumes are stored on the device at `/var/lib/wendy/volumes/<name>/`. They survive container restarts and image updates. To pre-seed data (model weights, databases, etc.) in an air-gapped deployment, copy files directly to the volume path before starting the container:

```sh
sudo mkdir -p /var/lib/wendy/volumes/huggingface-cache
sudo cp -r /mnt/transfer/hf-models/* /var/lib/wendy/volumes/huggingface-cache/
```

The agent mounts this directory into the container when the `persist` entitlement references that volume name.
