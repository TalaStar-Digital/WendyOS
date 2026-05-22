# Wendy for Mac

Wendy for Mac is in progress for teams that want the Wendy deploy, manage, and debug workflow on headless Apple Silicon Macs.

Unlike WendyOS devices, Mac targets are not flashed with a WendyOS image. They use a macOS-specific `wendy-agent` path on the existing operating system.

## Target Hardware

- Mac mini
- Mac Studio
- Other headless Apple Silicon Macs

## Planned Workflow

```bash
wendy discover
wendy device set-default
wendy run
```

The goal is to make a headless Mac behave like any other Wendy device from the developer machine: discover it, select it, deploy apps to it, and debug remotely.

## Status

Wendy for Mac is in progress. Cloud fleet management and Jetson AGX Orin support are both imminent, while Jetson AGX Thor support remains in progress.
