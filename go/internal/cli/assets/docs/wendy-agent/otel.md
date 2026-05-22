Wendy-Agent comes with an Open Telemetry collector built-in. This exposes both gRPC and plain HTTP endpoints, exposed only to localhost, for end-user apps to connect to.

> **TODO (test)**: OTel hasn't been tested IIRC, we should set up CI for both.

The collector receives your (structured) logs, metrics and traces. If [Wendy Cloud](../cloud/) is set up, the device will forward this data over to the cloud. If a [Client](../cloud/) has permissions, it can request to see the logs using [`wendy device logs`](../clients/wendy-cli/commands/device/logs.md). This will also forward the logs to this device. Wendy-CLI has similar commands as well, like a [dashboard](../clients/wendy-cli/commands/device/dashboard.md) and [JSON telemetry stream](../clients/wendy-cli/commands/device/telemetry-stream.md)

Any `stdout` emitted (through print statements) will be converted into OTel logs as well, and the app's ID will be attached as the originating service.