# WendyAgentE2ETests

Minimal Swift E2E scaffolding built around an SSH-only `Machine` helper.

## Run tests

```bash
cd swift/WendyAgentE2ETests
swift test
```

## Machine spec

`Machine` uses a compact SSH spec:

- `user@host:/path/to/repo`

The SSH session is persisted with an OpenSSH control socket, so the first
command authenticates and later commands reuse the same connection.

## Run the smoke test

The smoke test is gated behind `WENDY_E2E_SMOKE=1` and requires one remote
machine spec:

```bash
cd swift/WendyAgentE2ETests
WENDY_E2E_SMOKE=1 \
E2E_MACHINE='user@host:~/wendy-agent' \
swift test --filter MachineSmokeTests
```
