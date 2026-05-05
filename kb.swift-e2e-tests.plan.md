# Plan: implement the Swift E2E behavior spec

## Goal

Implement the existing Swift E2E test stubs in `swift/WendyAgentE2ETests` as
a complete executable specification of the desired Wendy CLI, agent, device,
cloud, and project behavior.

The stubs already define the first draft of the spec. The work here is not to
choose a small deterministic subset, and not to encode today's partial
implementation as correct. The work is to turn each stub into an executable
verification of the behavior we want the product to have.

## Guiding principle

The E2E suite is the product spec.

Every test should describe the final desired behavior from the user's point of
view, even when making that test executable requires fixtures, local services,
real devices, cloud accounts, generated projects, or substantial setup. Test
complexity is secondary to specification completeness.

If the current Mac Agent returns
`RPCError(code: .unimplemented, message: "... currently not supported on macOS.")`
for a behavior that the product should eventually support, the E2E test should
not pass by asserting that error. Instead, it should assert the desired behavior
and expose the `.unimplemented` result as an implementation gap.

Only assert `.unimplemented` as success when unsupported behavior is itself the
intended user-facing contract.

## Scope

Implement all existing stubs under:

```text
swift/WendyAgentE2ETests/Tests/WendyAgentE2ETests
```

The current files and test names are the baseline spec. Do not delete stubs to
make the suite smaller. If a stub's behavior is ambiguous, clarify the expected
user behavior in the test body and, when useful, with `// AI:` review notes.

## Test implementation model

For every stub:

1. Identify the user-facing command and scenario named by the test.
2. Define the desired stdout, stderr, exit status, JSON shape, and side effects.
3. Build whatever fixture is needed to make that scenario executable.
4. Run the real CLI/agent path whenever possible.
5. Assert the desired behavior directly.
6. Leave failures as useful evidence of missing implementation, not as empty
   passing tests.

## Fixtures and infrastructure

Add helper infrastructure as needed, but keep it in service of the spec:

- temporary `HOME` and config directories
- temporary Wendy projects and generated `wendy.json` files
- local fake Wendy Cloud services where cloud behavior must be deterministic
- local fake or simulated WendyOS agents where hardware/device behavior must be
  deterministic
- real-device gates for behaviors that cannot be simulated faithfully
- local Mac Agent lifecycle helpers for commands that intentionally exercise the
  Mac Agent path
- project builders and sample apps for build/run/deploy specs
- reusable JSON and output assertion helpers

Do not avoid a test because the fixture is involved. If a behavior matters to
users, specify it and make it verifiable.

## Handling current implementation gaps

Some desired behaviors are not implemented yet, especially in the Mac Agent.
For those:

- The E2E test should assert the desired final behavior.
- If the command currently fails with gRPC `Unimplemented`, treat that as a
  failing implementation gap, not the desired result.
- If the project needs the default suite to stay green temporarily, use an
  explicit known-issue mechanism or clearly gated execution, but keep the
  desired assertions in the test.
- Generated command records should make the gap obvious, including the current
  `.unimplemented` error when that is what happened.

This keeps the suite useful as both spec and backlog.

## Assertions

Prefer strong, user-facing assertions:

- exact output for stable short messages
- parsed JSON shape and values for `--json`
- non-zero exit plus clear diagnostic for intended failure cases
- real filesystem/config side effects for commands that write state
- observable device/agent/cloud effects for integration scenarios
- readable progress/log output for long-running commands

Avoid assertions that merely preserve accidental current behavior.

## Implementation order

Implement the existing stubs in coherent command families:

1. top-level CLI, help, completion, info, analytics, json
2. project initialization and project configuration
3. project entitlements
4. build and run
5. cache and OS cache
6. discovery and device selection/default-device behavior
7. device version, dashboard, logs, telemetry, update
8. device apps and volumes
9. device hardware, camera, audio, Bluetooth, WiFi
10. OS image download, install, list-drives, update
11. auth and cloud-backed flows
12. tour and utilities

This order is for reviewer convenience only. It is not a statement that later
areas are optional.

## Running tests

Use an explicit records directory while iterating:

```bash
cd swift/WendyAgentE2ETests
WENDY_AGENT_E2E_TEST_RECORDS_DIR="$PWD/.build/e2e-test-records.current" swift test
```

For focused work:

```bash
swift test --filter '<suite-or-test-fragment>'
```

Inspect the Markdown command records after each command family. The records are
part of the feedback loop: they should show whether the implementation matches
the spec or where it falls short.

## Acceptance criteria

This work is successful when:

1. Every existing E2E stub contains executable spec assertions.
2. No test passes only because its body is empty.
3. Desired behavior is asserted even for features not implemented yet.
4. Current `.unimplemented` Mac Agent responses are visible as gaps unless they
   are the intentional product contract.
5. Fixtures, fakes, gates, and helpers exist wherever needed to make the spec
   verifiable.
6. Command records provide clear evidence for both passing behavior and missing
   implementation.
