# OCI Entitlements

The wendy agent translates [app entitlements](../../apps/wendy.json.md#entitlements-1) declared in `wendy.json` into concrete OCI runtime spec settings before a container is started. This document describes how each entitlement is applied at the OCI layer.

## Default container spec

Every container starts from a baseline spec produced by `DefaultSpec()`. This baseline includes:

- A **minimal Linux capability set** (see [Capabilities](#capabilities)).
- A **default seccomp profile** that allows all syscalls except known container-escape primitives (see [Seccomp profile](#seccomp-profile)).
- Standard mounts, masked paths, and cgroup configuration.

Entitlements then augment this baseline — they can add capabilities, devices, mounts, and environment variables, but they cannot remove the seccomp filter.

---

## Capabilities

### Default capabilities

All containers receive the following capabilities by default:

| Capability | Purpose |
|---|---|
| `CAP_CHOWN` | File ownership changes inside the container |
| `CAP_DAC_OVERRIDE` | Bypass file permission checks |
| `CAP_FSETID` | Set SUID/SGID bits |
| `CAP_FOWNER` | Bypass ownership checks |
| `CAP_MKNOD` | Create special files |
| `CAP_NET_RAW` | Raw sockets |
| `CAP_SETGID` | Manipulate group IDs |
| `CAP_SETUID` | Manipulate user IDs |
| `CAP_SETFCAP` | Set file capabilities |
| `CAP_SETPCAP` | Transfer/drop capabilities |
| `CAP_NET_BIND_SERVICE` | Bind to privileged ports |
| `CAP_KILL` | Send signals |
| `CAP_AUDIT_WRITE` | Kernel audit log |

### Capabilities never granted

The following capabilities are explicitly **absent** from both the default set and the device-entitlement set:

| Capability | Why it was removed |
|---|---|
| `CAP_SYS_CHROOT` | Containers have their own mount namespace; `chroot(2)` is unnecessary and was a filesystem-escape vector (WDY-1099). |
| `CAP_SYS_PTRACE` | Audio/camera/video access does not require process tracing. This capability was the primary vector for a container escape via device entitlements (WDY-1099). |

### `CAP_NET_ADMIN`

`CAP_NET_ADMIN` is **not** granted by default. It is added only when a `host` network entitlement is present, where it is required to manipulate the host network stack.

---

## Seccomp profile

Every container receives a seccomp filter with `SCMP_ACT_ALLOW` as its default action. This means all syscalls are permitted unless explicitly denied.

The following syscalls are denied with `EPERM`:

| Syscall / rule | Reason |
|---|---|
| `ptrace` (unconditional) | Reading/writing arbitrary process memory; no legitimate in-container use. |
| `unshare` (unconditional) | Namespace detachment can be used to escape container isolation. |
| `clone` when bit `0x10000000` (`CLONE_NEWUSER`) is set | Unprivileged user-namespace creation is the classic container-escape primitive. Matched via `SCMP_CMP_MASKED_EQ` so normal thread-creation calls are unaffected. |

The profile is applied unconditionally by `DefaultSpec()` and cannot be overridden by individual entitlements.

---

## Hardware device entitlements

When a container is granted a device entitlement (camera, microphone, speakers, video), `SetDeviceCapabilities()` is called in addition to the default capabilities. The device capability set mirrors the default set and:

- Does **not** add `CAP_SYS_PTRACE`.
- Does **not** add `CAP_SYS_CHROOT`.

Device nodes are bind-mounted into the container with `noexec` set.

---

## Network entitlements

| Mode | OCI effect |
|---|---|
| `host` | Shares the host network namespace; adds `CAP_NET_ADMIN`. |
| *(default)* | Isolated network namespace; no extra capabilities. |
| `none` | Loopback-only network namespace. |

---

## Persistent storage entitlements

`persist` entitlements create a named volume on the host and bind-mount it at the declared path inside the container. Volumes survive container restarts and re-deployments.

The `path` field describes a destination inside the Linux container. It is validated using POSIX path semantics regardless of the host OS running the CLI or agent, so paths such as `/data` and `/models` are always accepted and host-style paths such as `C:\data` are always rejected.

The OCI mount destination is cleaned using POSIX rules before the spec is written.

---

## Code signing

Entitlements are [code signed](./codesigning.md) and verified by the agent before a container is started. A container cannot claim entitlements that were not present in its signed configuration.
