# WendyAgentE2ETests

Minimal Swift E2E scaffolding built around an SSH-only `Machine` helper.

## Run tests

```bash
cd swift/WendyAgentE2ETests
swift test
```

## Machine configuration

`Machine` takes the SSH target and optional remote working directory separately:

```swift
let machine = Machine(ssh: "user@host", path: "/path/to/repo")
```

If `path` is omitted, commands run in the SSH user's home directory.
Each command runs in its own SSH invocation.

## Run the smoke test

The smoke test is gated behind `WENDY_E2E_SMOKE=1` and requires an SSH target.
`E2E_MACHINE_PATH` is optional and defaults to the SSH user's home directory:

```bash
cd swift/WendyAgentE2ETests
WENDY_E2E_SMOKE=1 \
E2E_MACHINE_SSH='user@host' \
E2E_MACHINE_PATH='/path/to/wendy-agent' \
swift test --filter MachineSmokeTests
```
