# Hardware Access

Wendy apps run in isolated containers by default. Hardware such as cameras, microphones, speakers, Bluetooth adapters, and GPUs is not exposed to an app unless the app declares an entitlement in `wendy.json`.

Use the Wendy CLI to add entitlements:

```bash
wendy project entitlements add
```

Run the command with no arguments for an interactive menu, or pass the entitlement directly:

```bash
wendy project entitlements add camera
wendy project entitlements add audio
wendy project entitlements add bluetooth
wendy project entitlements add gpu
```

Then deploy normally:

```bash
wendy run
```

## Common Hardware

| Hardware | Entitlement | Use When |
|---|---|---|
| USB or CSI camera | `camera` | Capturing frames, streaming video, computer vision |
| Microphone | `audio` | Recording, voice commands, audio analysis |
| Speaker or audio output | `audio` | Playback, alerts, voice responses |
| Bluetooth adapter | `bluetooth` | BLE devices, Bluetooth sensors, paired accessories |
| NVIDIA GPU | `gpu` | CUDA, ML inference, accelerated computer vision |
| Web servers or network APIs | `network` | Serving HTTP, WebSockets, or accepting inbound connections |

## Hardware Guides

- [Camera access](hardware-camera.md)
- [Microphone access](hardware-microphone.md)
- [Speaker access](hardware-speakers.md)
- [Bluetooth access](hardware-bluetooth.md)
- [GPU access](hardware-gpu.md)

For the full entitlement schema and options, see [wendy.json — Entitlements](../apps/wendy.json.md#entitlements-1).
