The Wendy-Agent, on *OCI enabled devices*, offers a container registry, which [clients](../../clients) can use to **upload** apps.

> **TODO**: The registry is currently a normal one, which means apps can also be deleted. This should not be allowed.

The standard container registry spec is available over plaintext HTTP for unprovisioned devices.

HTTPS is provided by the container registry when a device is provisioned. The registry uses the device's mTLS certificate, signed by the Wendy Cloud Root CA, which is not in the macOS system keychain.

When the CLI communicates with the registry on a provisioned device, it does so through an HTTP→HTTPS reverse proxy (`startMTLSRegistryHTTPProxy`). The proxy presents the developer's mTLS client certificate to the registry and validates the registry's server certificate against the Wendy CA chain. Hostname verification is skipped because device certificates are signed by the Wendy CA but may not include the mDNS hostname as a Subject Alternative Name (SAN); full chain and extended key usage (EKU) validation is performed via a `VerifyConnection` hook instead. If the provided CA PEM contains no valid certificates, the proxy fails to start.

> **TODO (urgent)**: The Container Registry must validate an authorized developer is accessing its contents.

When uploading via the **Swift container plugin** to a provisioned LAN device, the CLI automatically starts a local plain-HTTP reverse proxy on `127.0.0.1` that terminates TLS and handles mTLS client-certificate authentication transparently. The Swift plugin connects to this local proxy via plain HTTP (using `--allow-insecure-http`) and the proxy forwards requests to the device's HTTPS registry using the CLI's mTLS certificate and the Wendy Cloud Root CA chain for server verification.

The registry effectively acts as an HTTP(S) proxy for containerd, so when pushing a container to the registry, it is directly injected into `containerd`. This way we don't duplicate data between registry and containerd, saving disk space.

> **IDEA**: Containerd can also pull artifacts, for example, from [Wendy Cloud](../../cloud). This means we could disable the registry on production devices entirely.
