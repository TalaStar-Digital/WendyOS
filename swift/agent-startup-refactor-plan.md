# WendyAgent startup refactor plan

## Goal

Refactor `WendyAgent` startup to be deterministic, sequential, and easy
to reason about.

## Decisions already made

- Keep everything in `WendyAgent`
- Do **not** introduce a `WendyAgentComponent` abstraction for now
- Do **not** split orchestration into `WendyAgent` and
  `WendyAgentRuntime`
- Keep `.starting`
- Do **not** use timing-based readiness or startup probes
- Docker remains optional
- `.running` should only be set after all required subsystems are
  actually ready

## Required startup semantics

Normal startup should mean:

1. set status to `.starting`
2. perform startup work step by step
3. wait for each required subsystem to report real readiness
4. switch to `.running` only after all required subsystems are actually
   started
5. monitor long-lived runtime tasks for unexpected exit

Required subsystems:

- main Wendy Agent gRPC server
- local OpenTelemetry gRPC server
- Bonjour advertisement

Optional subsystem:

- Docker preflight / local registry setup

## Why this change is needed

The old startup flow mixed:

- sequential setup work
- long-lived runtime execution
- inferred readiness via timing/probe behavior

That made startup hard to reason about and caused the menu to stay on
`Starting...` even after the runtime was effectively alive.

The replacement should be:

- deterministic
- explicit
- based on real readiness
- easy to extend later when startup gains more work

---

# Subsession plan

Each subsession should focus on **one step only**.
Do not attempt the whole refactor in one go.

## Commit strategy for every step

This refactor should be committed **often**.
Do not save up a whole step's work for one large commit if it can be
reviewed more clearly as a short sequence.

Use commits to tell a human-reviewable story:

1. commit preparatory layout changes separately from behavior changes
2. commit the readiness/startup behavior separately from cleanup
3. commit tests separately when that makes the intent clearer
4. keep each commit small enough that a reviewer can understand its
   purpose without mentally reconstructing unrelated edits
5. prefer a few coherent commits per step over one large mixed commit

For each step, aim to leave behind:

- a short progress note in this file when useful
- one or more commits with a clear narrative order
- a handoff prompt for the **next** step, not the current one

If a step naturally breaks into sub-parts, commit after each sub-part as
long as the tree still builds or the partial state is clearly
intentional and easy to review.

## Step 1 — Audit readiness APIs

### Goal

Figure out how to get a real readiness signal for:

- main gRPC server
- local OTel gRPC server

### Scope

- audit only
- minimal or no refactoring
- record findings back into this file or a short follow-up note

### Constraints

- keep everything in `WendyAgent`
- no component abstraction
- no timing/probe readiness logic

### Questions to answer

1. Does the current `GRPCServer` API expose a real startup/readiness
   signal?
2. If not, what lower-level API can tell us when bind/listen succeeds?
3. What concrete runtime state will we need to keep for each server?

### Done when

- there is a clear plan for how each server can report deterministic
  readiness
- we know whether `ServiceGroup` can stay in the picture or should be
  bypassed for startup orchestration

### Audit findings

- `GRPCServer.serve()` does **not** itself return a startup milestone. It
  is a long-lived call that only returns once the server stops.
- The `GRPCServiceLifecycle` conformance used by `ServiceGroup` just maps
  `run()` to `serve()` behind a graceful-shutdown handler, so it also does
  **not** expose a readiness callback.
- The current transports are `HTTP2ServerTransport.Posix`, and that type
  **does** conform to `ListeningServerTransport`.
- Because of that, `GRPCServer` exposes `listeningAddress` as an async
  property when the transport supports it. That property completes only
  after the underlying NIO listener has actually bound.
- In `grpc-swift-nio-transport`, readiness is backed by the transport's
  internal `listeningAddress` promise, which is fulfilled only after
  `ServerBootstrap.bind(...)` succeeds and a listening channel exists.
- So the deterministic readiness point for both the main gRPC server and
  the local OTel gRPC server is:
  1. create the `GRPCServer`
  2. start `server.serve()` in a task
  3. await `server.listeningAddress`
  4. only treat the server as started if that await succeeds
- If we ever need to bypass `GRPCServer` entirely, the next lower-level
  readiness API is NIO's `ServerBootstrap.bind(...)`, whose successful
  return means bind/listen succeeded. That fallback does not appear
  necessary right now because `listeningAddress` already gives us the same
  readiness signal through the current transport.
- Concrete runtime state we will need to retain per server in later steps:
  - the `GRPCServer<HTTP2ServerTransport.Posix>` instance, so shutdown can
    call `beginGracefulShutdown()`
  - the long-lived `Task<Void, Error>` running `serve()`
  - optionally the resolved listening address for logging/diagnostics
- `ServiceGroup` is still fine as a container for "run these services until
  shutdown", but it is a poor fit for deterministic startup orchestration:
  it starts child services concurrently and provides no per-service started
  barrier. Since the desired startup flow is explicit and sequential,
  startup orchestration should likely bypass `ServiceGroup` and start the
  required subsystems directly from `WendyAgent`.

### Handoff prompt for Step 2

> Continue with Step 2 from `agent-startup-refactor-plan.md`.
> Reshape `WendyAgent` state and private helper layout for deterministic
> startup. Keep behavior changes minimal in this step. Commit in small,
> reviewable slices so the structural preparation is easy to follow.

---

## Step 2 — Reshape `WendyAgent` state and helper layout

### Goal

Prepare `WendyAgent` for deterministic startup by simplifying stored
state and extracting concrete private helpers.

### Scope

- structural cleanup only
- avoid major behavior changes if possible

### Target shape

`WendyAgent` should directly own concrete runtime state such as:

- status
- main server runtime state
- OTel server runtime state
- Bonjour runtime state
- monitor task

Representative conceptual shape:

```swift
@MainActor
final class WendyAgent {
    private(set) var status: WendyAgentStatus = .stopped

    private var mainServerTask: Task<Void, Error>?
    private var otelServerTask: Task<Void, Error>?
    private var bonjourRegistration: BonjourRegistration?
    private var monitorTask: Task<Void, Never>?
}
```

The exact types may differ.

### Helpers to introduce or prepare

- `prepareDockerIfNeeded() async -> Bool`
- `startMainServer(dockerAvailable:) async throws -> ...`
- `startOTelServer() async throws -> ...`
- `startBonjour() async throws -> ...`
- `startMonitorTask()`
- `rollback(...) async`
- `clearRuntimeState()`

### Constraints

- no component abstraction
- no timing hacks
- no broad status-model redesign in this step

### Done when

- `WendyAgent` is structurally ready for deterministic startup work
- the follow-up steps can focus on behavior instead of layout

### Step 2 progress

- `WendyAgent` now has explicit stored runtime slots for the main gRPC
  server, local OTel server, Bonjour advertiser, and monitor task instead
  of only a generic top-level run/monitor pair.
- Startup construction work was split into concrete private helpers:
  `prepareDockerIfNeeded()`, `startMainServer(...)`,
  `startOTelServer(...)`, `startBonjour()`, `startMonitorTask(...)`,
  `rollback()`, and `clearRuntimeState()`.
- `ServiceGroup` is still temporarily used as the long-lived runtime
  container so Step 2 stays mostly structural. Later steps can replace the
  actual startup behavior without first untangling the layout.
- Logging bootstrap, status observation, and overall startup/status
  behavior remain intentionally close to the pre-refactor flow in this
  step.

### Handoff prompt for Step 3

> Continue with Step 3 from `agent-startup-refactor-plan.md`.
> Implement deterministic startup for the main Wendy Agent gRPC server.
> The helper should return only when the server is actually ready.
> Prefer separate commits for structural adjustments vs. readiness
> behavior if that makes the review easier.

---

## Step 3 — Implement deterministic main gRPC server startup

### Goal

Make the main Wendy Agent gRPC server start through a helper that only
returns once the server is actually ready.

### Scope

- main server only
- no full `start()` rewrite yet unless absolutely necessary

### Requirements

- helper returns only after bind/listen success
- helper gives `WendyAgent` enough runtime state to stop and monitor the
  server later
- no readiness timing/probe logic

### Done when

- main server startup has a real readiness point
- the helper can be used as one step in future sequential startup

### Step 3 progress

- `startMainServer(...)` now launches `server.serve()` in its own task,
  awaits `server.listeningAddress`, and returns only after the main gRPC
  listener has actually bound.
- `MainServerRuntime` now retains both the `GRPCServer` instance and its
  long-lived serve task so later steps can shut it down and monitor it
  explicitly.
- The main gRPC server is no longer started indirectly through the
  `ServiceGroup`; the temporary `ServiceGroup` container now only carries
  the not-yet-refactored OTel and Bonjour services.
- Startup rollback and shutdown paths now gracefully stop the already
  started main gRPC server instead of just dropping stored state.

### Handoff prompt for Step 4

> Continue with Step 4 from `agent-startup-refactor-plan.md`.
> Implement deterministic readiness for the local OTel server and
> Bonjour advertisement. Keep the commits small and ordered so each
> subsystem's readiness work is easy to review.

---

## Step 4 — Implement deterministic OTel and Bonjour startup

### Goal

Give the remaining required subsystems explicit readiness behavior.

### Scope

- local OTel gRPC server
- Bonjour advertisement

### Requirements

- OTel helper returns only after bind/listen success
- Bonjour helper returns only after registration succeeds
- runtime state is usable for later shutdown/monitoring

### Done when

- all required startup pieces have explicit readiness
- `WendyAgent` can eventually transition to `.running` based on real
  startup completion rather than timing

### Step 4 progress

- `startOTelServer(...)` now mirrors the main server startup path: it
  launches `serve()` in its own task, awaits `listeningAddress`, and
  retains both the server and serve task for later shutdown.
- Bonjour advertising no longer relies on `ServiceGroup` startup timing.
  `BonjourAdvertiser.start()` now waits for the DNS-SD registration
  callback before returning a runtime handle.
- `WendyAgent` now stores explicit Bonjour runtime state and shuts it
  down directly, which removes the last required subsystem from the
  temporary `ServiceGroup`-based startup path.

### Handoff prompt for Step 5

> Continue with Step 5 from `agent-startup-refactor-plan.md`.
> Rewrite `WendyAgent.start()` and `stop()` as explicit sequential
> orchestration using the new readiness helpers. Use commit boundaries to
> separate orchestration changes from any incidental cleanup.

---

## Step 5 — Rewrite `start()` and `stop()` sequentially

### Goal

Make startup and shutdown read as simple top-to-bottom orchestration.

### Desired `start()` behavior

1. return early if already started
2. set status to `.starting`
3. perform optional Docker setup
4. start main server and wait for readiness
5. start OTel server and wait for readiness
6. start Bonjour and wait for readiness
7. store runtime state
8. start monitor task
9. set status to `.running`

### Desired `stop()` behavior

1. return early if not running
2. request shutdown of started pieces in a predictable order
3. wait for long-lived tasks to finish
4. clear stored runtime state
5. set status to `.stopped`

### Constraints

- no timing-based readiness logic
- no `ServiceGroup`-driven readiness inference
- keep Docker optional

### Done when

- `start()` is clearly sequential and deterministic
- `stop()` is explicit and predictable
- `.running` is only set after required startup really completed

### Handoff prompt for Step 6

> Continue with Step 6 from `agent-startup-refactor-plan.md`.
> Simplify runtime monitoring, cleanup, and logging after the sequential
> startup/shutdown rewrite. Commit monitoring changes separately from log
> cleanup when that improves reviewability.

---

## Step 6 — Simplify monitoring and cleanup

### Goal

Keep only the runtime monitoring needed for unexpected exits and remove
obsolete startup artifacts.

### Scope

- monitor task behavior
- runtime cleanup paths
- logging cleanup
- remove no-longer-needed probe/timing leftovers

### Requirements

- unexpected runtime exit transitions status away from `.running`
- stored runtime state is cleared consistently
- logging remains useful but not noisy

### Done when

- runtime failure handling is understandable
- startup logic no longer contains leftover workarounds

### Handoff prompt for Step 7

> Continue with Step 7 from `agent-startup-refactor-plan.md`.
> Add or update tests to lock in deterministic startup and shutdown
> behavior. Prefer separate commits for behavioral fixes and test
> coverage when that tells the story more clearly.

---

## Step 7 — Tests and polish

### Goal

Lock in the desired startup/shutdown behavior.

### Tests to add or update

- startup reaches `.running` only after required startup completes
- Docker unavailability does not block startup
- required subsystem startup failure prevents `.running`
- shutdown transitions back to `.stopped`
- unexpected runtime exit transitions away from `.running`

### Done when

- behavior is covered well enough to protect the refactor
- remaining logs/comments reflect the final design

### Final handoff prompt

> The startup refactor plan steps are complete. Review the resulting
> startup/shutdown flow end to end, confirm the commit sequence tells a
> clear story, and capture any follow-up cleanup as separate,
> reviewable work rather than folding it into the finished refactor.

---

# Notes for the future session

## Important implementation note

This refactor depends on getting a real readiness signal for both gRPC
servers.

If `GRPCServer` only exposes a long-lived `run()` API and not a true
started/bound signal, then the refactor should likely go one level lower
for server startup rather than inventing another timing-based heuristic.

## Logging guidance

Keep:

- startup began
- Docker unavailable or Docker startup warning
- transition to running
- unexpected runtime stop/failure
- shutdown completion if useful

Avoid verbose per-stage logs unless they are temporarily needed while a
step is in progress.

## Status guidance

No separate status simplification has been decided yet.
For now, the important behavioral rule is only:

- `.running` must mean required subsystems are actually ready

## Success criteria for the whole refactor

The overall refactor is successful if:

- `WendyAgent.start()` reads as simple sequential startup logic
- `.starting` remains visible during real startup work
- `.running` is set only after required subsystems are truly ready
- no timing-based readiness logic remains
- Docker remains optional
- shutdown is explicit and predictable
- the code is easier to understand than the current startup path
