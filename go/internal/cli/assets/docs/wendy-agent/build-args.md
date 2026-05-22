# Docker Build Args

When `wendy run` builds your container image, it automatically injects a set of `WENDY_*` build arguments. Dockerfiles can declare these with `ARG` to adapt their build to the target device without any manual configuration.

## Available Build Args

### `WENDY_PLATFORM`

Always set. Maps the device type to a platform tier for selecting base images.

| Value | Devices |
|---|---|
| `nvidia-jetson` | `jetson-agx-orin`, `jetson-orin-nano` |
| `generic` | All other devices (CPU-only) |

Use this to select an appropriate base image:

```dockerfile
ARG WENDY_PLATFORM=generic

FROM nvcr.io/nvidia/l4t-pytorch:r36.2.0-pth2.1-py3 AS nvidia-jetson
FROM python:3.11-slim AS generic

FROM ${WENDY_PLATFORM}
```

### `WENDY_DEVICE_TYPE`

Set when the agent reports a specific device type. Not set on older agent versions — Dockerfiles should declare a default or handle absence.

Known values: `jetson-agx-orin`, `jetson-orin-nano`

```dockerfile
ARG WENDY_DEVICE_TYPE
RUN echo "Building for: ${WENDY_DEVICE_TYPE:-unknown}"
```

### `WENDY_HAS_GPU`

Set when the agent reports GPU presence. `"true"` if the device has a GPU, `"false"` if it does not. Not set on older agent versions — declare a default.

```dockerfile
ARG WENDY_HAS_GPU=false
RUN if [ "$WENDY_HAS_GPU" = "true" ]; then pip install torch --index-url https://download.pytorch.org/whl/cu121; fi
```

### `WENDY_GPU_VENDOR`

Set when the agent reports a GPU vendor. Currently `"nvidia"` on Jetson devices. Not set on older agents or CPU-only devices.

```dockerfile
ARG WENDY_GPU_VENDOR
```

### `WENDY_JETPACK_VERSION`

Set on Jetson devices. The JetPack version string (e.g. `"6.1"`). Not set on non-Jetson devices or older agents.

```dockerfile
ARG WENDY_JETPACK_VERSION
```

### `WENDY_CUDA_VERSION`

Set when the agent reports a CUDA version (e.g. `"12.6"`). Not set on CPU-only devices or older agents.

```dockerfile
ARG WENDY_CUDA_VERSION
```

### `WENDY_DEBUG`

Always set. `"true"` when `wendy run --debug` is passed, `"false"` otherwise.

Use this to include debug tooling only in development builds:

```dockerfile
ARG WENDY_DEBUG=false
RUN if [ "$WENDY_DEBUG" = "true" ]; then pip install debugpy; fi
```

## Hook Environment Variables

The following variables are expanded inside `postStart` hooks in `wendy.json`. They are **not** Docker build args. Both Unix-style (`${VAR}`) and Windows-style (`%VAR%`) forms are supported for these variables.

| Variable | Value |
|---|---|
| `WENDY_HOSTNAME` | Device mDNS hostname (e.g. `wendyos-humble-pepper.local`) |
| `WENDY_APP_ID` | App ID from `wendy.json` |

Use `openURL` to open a URL in the developer's default browser portably across macOS, Linux, and Windows — the CLI dispatches it directly without a shell:

```json
{
  "hooks": {
    "postStart": {
      "openURL": "http://${WENDY_HOSTNAME}:3000"
    }
  }
}
```

The `cli` field accepts a free-form shell command and also supports variable expansion. However, `open`, `xdg-open`, and `start` are platform-specific; prefer `openURL` for opening URLs:

```json
{
  "hooks": {
    "postStart": {
      "cli": "echo App started on ${WENDY_HOSTNAME}"
    }
  }
}
```
