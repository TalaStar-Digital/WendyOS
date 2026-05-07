# WendyAgentE2ETests

Swift E2E test package for the Wendy CLI and local Wendy agent. The long-term goal is to use this package as a behavioral specification suite, not just a collection of smoke tests.

## Running tests

From this package:

```bash
swift test --filter WendyAgentE2ETests
```

For reproducible command records:

```bash
WENDY_AGENT_E2E_TEST_RECORDS_DIR="$PWD/.build/e2e-test-records.current" \
  swift test --filter WendyAgentE2ETests
```

To render the HTML report from the repository root:

```bash
.agents/skills/run-e2e-tests-and-analyze/render-e2e-report.py \
  --records-dir swift/WendyAgentE2ETests/.build/e2e-test-records.current
```

## Behavioral spec workflow

Use this workflow when expanding E2E coverage for a command area.

1. Pick one bounded command area.
2. Write disabled Swift Testing stubs only.
3. Review the stubs as the product/API behavior spec.
4. Once agreed, implement the specs one by one.

The disabled stubs are the durable specification. They should describe externally observable behavior, not current implementation details.

Good first command areas are local and deterministic:

- `wendy init`
- `wendy json validate`
- `wendy project entitlements`
- `wendy cache`
- `wendy analytics`

Avoid starting with areas that require live agents, browsers, hardware, streaming, cloud auth, or network discovery.

## Spec stub style

Use disabled tests so unimplemented specs do not falsely pass:

```swift
@Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
func `creates a minimal Swift WendyOS project non-interactively`() async throws {
    // Given: an empty temporary directory
    // When: `wendy init` is run with app id, target, language, no extra entitlements, and no git init
    // Then:
    // - exits successfully
    // - writes wendy.json
    // - writes Package.swift
    // - emits concise success guidance on stdout
    // - emits no stderr diagnostics
}
```

A good spec stub:

- reads like product documentation
- names one user-visible behavior
- states setup, action, and expected outcomes
- identifies filesystem/config mutations and non-mutations
- avoids asserting incidental current wording unless the wording is itself the contract

## What to specify

For each command area, build a behavioral matrix before implementing test bodies:

- happy paths
- invalid input
- missing state
- existing state
- idempotency
- cancellation and prompts
- non-interactive behavior
- human output vs JSON output
- stdout/stderr contract
- exit status
- filesystem side effects
- config mutation and non-mutation
- analytics/environment isolation

For human-readable output, prefer semantic anchors. For JSON and config files, prefer exact structure and meaningful fields.

## Definition of a good implemented spec

An implemented E2E spec should be deterministic and hermetic where possible:

- use temporary project directories
- use temporary `HOME`/config directories
- avoid real browser, cloud, hardware, live device, network, and clock dependencies unless explicitly under test
- assert exit status
- assert stdout/stderr behavior
- assert relevant file/config side effects
- assert no partial mutation on failure

Avoid broad assertions like:

```swift
#error contains domain-specific text || error contains "Could not connect"
```

Those are acceptable only for rough smoke coverage, not for a behavioral spec.

## Current recommended starting point

Start with `wendy init`.

Phase: spec stubs only; do not implement test bodies yet.

Goal: enumerate all externally observable behavior of project initialization:

- generated `wendy.json`
- generated language scaffold
- selected target/language behavior
- entitlement choices
- assistant options
- git initialization choices
- non-interactive behavior
- invalid metadata handling
- existing-file refusal
- failure non-mutation
- stdout/stderr contract

After the stubs read like a complete product/API spec, implement them incrementally.

## Cross-session handoff prompt

In a future session, use:

> Read `swift/WendyAgentE2ETests/README.md` and continue the behavioral spec workflow from the current recommended starting point. Do not implement test bodies until the disabled spec stubs are agreed.

## Machine and session overview

`Machine` is static metadata: identity, OS, tags, SSH target, and working directory. It does not run commands.

```swift
@Test(.enabled(if: Machine.cli.os == .linux))
func `uses linux behavior`() async throws {
    let cli = try await Session.begin(for: .cli)
    try await cli.sh("./bin/wendy --version")
    try await cli.end()
}
```

Known machines are declared as static properties:

```swift
Machine.current  // the test runner, tagged `.runner`
Machine.cli
Machine.agent
```

Predefined machine OS values are `.macOS`, `.linux`, `.windows`, and `.wendyOS`.
Use `WENDY_AGENT_E2E_CLI_OS` or `WENDY_AGENT_E2E_AGENT_OS` to override a known
machine's declared OS for a run.

`Session` is the runtime command executor for a machine:

```swift
let cli = try await Session.begin(for: .cli)
try await cli.sh("./bin/wendy --version")
```

Use `Session.with` when a spec needs cleanup-safe session lifetimes:

```swift
try await Session.with(.cli, .agent) { cli, agent in
    try await cli.sh("./bin/wendy --version")
    try await agent.sh("make build-dev")
}
```

Use `session.command(...).poll(...).run()` when a command needs DSL configuration before execution:

```swift
try await agent
    .command("nc -z 127.0.0.1 50051")
    .poll(until: .success)
    .run()
```

If `ssh` is omitted, sessions run commands locally. `Session.begin(for:verbose:)` enables command echoing for that session; `WENDY_AGENT_E2E_VERBOSE=1` enables it globally.
