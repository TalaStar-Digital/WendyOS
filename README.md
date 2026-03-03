# Wendy Agent & Wendy CLI

## Installing the CLI

### macOS (Homebrew)

```sh
brew tap wendylabsinc/tap
brew install wendy
```

For the nightly (prerelease) version:

```sh
brew tap wendylabsinc/tap
brew install wendy-nightly
```

To update:

```sh
brew upgrade wendy
```

### Linux

Debian/Ubuntu (`.deb`):

```sh
sudo apt install ./wendy_<version>_<arch>.deb
```

Fedora/RHEL (`.rpm`):

```sh
sudo rpm -i wendy-<version>.<arch>.rpm
```

Arch Linux (AUR):

```sh
yay -S wendy
```

Pre-built binaries for Linux, macOS, and Windows are available on the [Releases](https://github.com/wendylabsinc/wendy-agent/releases) page.

## Building from Source

### CLI (Go)

The CLI is written in Go. To build from source:

```sh
cd go
go build -o wendy ./cmd/wendy
```

On macOS, build with CGO enabled for Bluetooth (BLE) support:

```sh
cd go
CGO_ENABLED=1 go build -o wendy ./cmd/wendy
```

### Agent (Swift)

The wendy-agent requires **Swift 6.2** or later. On macOS, **Xcode 16.2** or later is needed.

To build and run the agent locally:

```sh
swift run wendy-agent
```


## Setting Up the Device

The device needs to run the `wendy-agent` utility. We provide pre-build [Wendy](https://wendyos.io) images for the Raspberry Pi and the NVIDIA Jetson Orin Nano. These are preconfigured for remote debugging and have the wendy-agent preinstalled.

### Network Manager Support

WendyAgent supports both NetworkManager and ConnMan for WiFi configuration. The agent will automatically detect which network manager is available on the system:

- **ConnMan** is preferred for embedded/IoT devices due to its lighter resource usage
- **NetworkManager** is supported for desktop and server environments
- The agent will automatically detect and use the available network manager

#### Configuration

You can configure the network manager preference using the `WENDY_NETWORK_MANAGER` environment variable on the agent:

```sh
# Auto-detect (default)
export WENDY_NETWORK_MANAGER=auto

# Prefer ConnMan if available, fall back to NetworkManager
export WENDY_NETWORK_MANAGER=connman

# Prefer NetworkManager if available
export WENDY_NETWORK_MANAGER=networkmanager

# Force ConnMan (will fail if not available)
export WENDY_NETWORK_MANAGER=force-connman

# Force NetworkManager (will fail if not available)
export WENDY_NETWORK_MANAGER=force-networkmanager
```

If no environment variable is set, the agent will auto-detect the available network manager.

#### Manual Setup

The `wendy` CLI communicates with a `wendy-agent`. The agent needs uses Docker for running your apps, so Docker needs to be running.
On a Debian (or Ubuntu) based OS, you can do the following:

```sh
# Install Docker
sudo apt install docker.io
# Start Docker and keep running across reboots
sudo systemctl start docker
sudo systemctl enable docker
# Provide access to Docker from the current user
sudo usermod -aG docker $USER
```

Then, you can download and run your `wendy-agent` on the device. We provide nightly tags with the latest `wendy-agent` builds [in this repository](https://github.com/wendylabsinc/wendy-agent/tags).

If you're planning to test the wendy-agent on macOS, you'll need to build and run the agent yourself from this repository.

```sh
swift run wendy-agent
```

## Examples

### Hello, world!

```sh
cd Examples/HelloWorld
wendy run
```

This builds the example using the Swift Static Linux SDK and runs it on your device in a container.

### Hello HTTP

A more advanced example demonstrating HTTP server capabilities:

```sh
cd Examples/HelloHTTP
wendy run
```

### Debugging

To debug an app, use the `--debug` flag:

```sh
wendy run --debug
```

You can then attach LLDB to port `4242`:

```sh
lldb
(lldb) target create .wendy-build/debug/HelloWorld
(lldb) gdb-remote localhost:4242
```

## Analytics

The Wendy CLI includes privacy-first anonymous usage analytics to help improve the developer experience. Analytics helps us understand which commands are used most, identify common errors, and prioritize improvements.

### What's Collected

- Command names and success/failure status
- Sanitized error types (no sensitive data)
- CLI version and operating system
- Anonymous identifier (UUID)

We **never** collect file paths, hostnames, project names, code, or any personally identifiable information.

### Managing Analytics

Check current analytics status:
```bash
wendy analytics status
```

Disable analytics:
```bash
wendy analytics disable
# Or set environment variable
export WENDY_ANALYTICS=false
```

Re-enable analytics:
```bash
wendy analytics enable
```

Analytics is automatically disabled in CI environments.
