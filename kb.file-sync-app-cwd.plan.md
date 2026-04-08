# Plan: launch macOS file-sync apps with their app directory as CWD

## Goal

When the Swift-based macOS Wendy agent launches a native app that was deployed
through the file-sync flow, the process should start with that app's synced
app directory as its current working directory.

For an app with ID `sh.wendy.examples.HelloMLX`, that means the launched
process should see:

```text
~/Library/Application Support/wendy-agent/apps/sh.wendy.examples.HelloMLX
```

as its CWD.

## Background

Today the macOS Swift agent already syncs app files into a per-app directory:

- `swift/Sources/WendyAgent/Services/FileSyncService.swift`
- `swift/Sources/WendyAgent/WendyAgent.swift`

The native app launch path then resolves the binary from that same app
directory in:

- `swift/Sources/WendyAgent/Services/ContainerService.swift`

However, `startContainer` currently sets:

- `process.executableURL`
- `process.arguments`
- stdio pipes

but does **not** set:

- `process.currentDirectoryURL`

So the launched app inherits the agent process's own working directory instead
of running from its synced app directory. That breaks relative-path access for
assets and any code that expects `.` to be the app's working tree.

## Scope

In scope:
- macOS Swift agent
- native app launch via the file-sync path
- both direct native launch and sandboxed native launch via the file-sync path
- making the launched process use the synced app directory as CWD
- automated coverage for the new launch behavior

Out of scope:
- Linux/containerd
- Docker-backed Linux containers on macOS
- Go CLI changes
- changing where file-sync stores files
- changing fallback `--appPath` launch behavior unless needed for refactoring

## Proposed change

### 1. Extend the existing native launch tuple in `ContainerService`

File:
- `swift/Sources/WendyAgent/Services/ContainerService.swift`

To stay merge-friendly with the `kb.run-args` work, do **not** introduce a new
struct here. Instead, extend the existing `appDirectories` tuple in the same
style so it can carry both launch args and an optional working directory.

Example direction:

```swift
private var appDirectories: [String: (
    directory: String,
    binaryName: String,
    args: [String],
    currentDirectory: String?
)] = [:]
```

Notes:
- only the file-sync registration path should populate `currentDirectory`
- legacy OCI and legacy `imageName` native registrations should leave
  `currentDirectory` unset
- this keeps the shape aligned with `kb.run-args`, reducing merge friction

### 2. Populate the app directory for the file-sync registration path

File:
- `swift/Sources/WendyAgent/Services/ContainerService.swift`

In `createContainer`, in the branch where:

- `imageName` is empty
- `cmd` carries the native binary name

store the synced app directory in the launch metadata.

Current behavior already computes:

- `appDirectory = appsBase.appendingPathComponent(appName).path`

That same `appDirectory` should become the process working directory for later
launch.

This branch should also keep following the `kb.run-args` shape by storing any
file-sync launch args alongside the binary name.

For non-file-sync native registrations:
- keep storing the directory / binary metadata needed for launch
- leave `currentDirectory` unset so this change remains scoped only to the
  file-sync path

### 3. Set `Process.currentDirectoryURL` before `run()`

File:
- `swift/Sources/WendyAgent/Services/ContainerService.swift`

In `startContainer`, when launching a native app that has registered file-sync
launch metadata, set:

```swift
process.currentDirectoryURL = URL(fileURLWithPath: entry.currentDirectory)
```

This should happen before `try process.run()` and only when
`entry.currentDirectory` is present.

Do **not** derive or set a working directory for:
- legacy OCI/native registrations
- legacy `imageName` native registrations
- fallback `--appPath` launches

Apply this for both file-sync launch variants:
- direct native launch
- sandboxed native launch via `/usr/bin/sandbox-exec`

The executable path stays the same; only the child process CWD changes for the
file-sync path.

### 4. Keep fallback launches unchanged

If `startContainer` falls back to `--appPath` because there is no registered
file-sync app entry, leave the working directory unset for now.

Why:
- keeps this change tightly scoped to the file-sync behavior the user asked for
- avoids making assumptions about what CWD standalone `--appPath` launches
  should use

If we later want deterministic behavior for fallback launches too, that can be
handled as a follow-up.

## Testing plan

### 1. Add a focused Swift test file

Create:
- `swift/Tests/WendyAgentTests/ContainerServiceTests.swift`

Use the existing Swift Testing setup already used by
`FileSyncServiceTests.swift`.

Prefer exercising `startContainer` directly through its existing streaming
response path. If that turns out to be too awkward in Swift Testing, add a
small test seam — but only as needed.

### 2. Add an integration-style test for effective runtime CWD

Test flow:
1. Create a temporary `appsBase`
2. Create `<appsBase>/<appID>/printpwd.sh`
3. Make it executable
4. Script contents should print its current working directory, for example:

```sh
#!/bin/sh
/bin/pwd
```

5. Instantiate `ContainerService` with that temporary `appsBase`
6. Call `createContainer` using the file-sync/native path:
   - `appName = <appID>`
   - `imageName = ""`
   - `cmd = "printpwd.sh"`
7. Call `startContainer`
8. Collect stdout from the response stream
9. Assert the printed path equals `<appsBase>/<appID>`

This verifies the behavior end to end instead of only checking internal state.

### 3. Keep the automated assertion minimal and positive

For this change, a single positive end-to-end assertion is sufficient:
- the launched script prints exactly `<appsBase>/<appID>`

A separate explicit negative assertion about the inherited test-runner CWD is
not required.

### 4. Add sandboxed file-sync launch coverage

Add a second integration-style test for the sandboxed file-sync launch path:
- write a fully permissive `sandbox.sb` into `<appsBase>/<appID>`
- launch the same `printpwd.sh` script through `startContainer`
- collect stdout from the response stream
- assert the printed path still equals `<appsBase>/<appID>`

Notes:
- this test should run unconditionally; if `/usr/bin/sandbox-exec` is not
  available or usable in the test environment, that should be a test failure,
  not a skip
- keep the assertion minimal and positive, just like the non-sandboxed case
- no extra assertion is required to prove the sandbox wrapper path was used;
  successful execution with `sandbox.sb` present plus the expected CWD check is
  sufficient for this plan

## Manual verification

After implementation:

1. Run a file-sync-based sample app such as HelloMLX
2. Have it print `FileManager.default.currentDirectoryPath`
3. Confirm it reports its synced app directory under:
   - `~/Library/Application Support/wendy-agent/apps/<appID>`
4. Verify relative asset lookups now work without needing absolute paths
5. Repeat the check with a file-sync app that includes `sandbox.sb` and confirm
   the reported CWD is still the synced app directory

## Risks / notes

- `Foundation.Process.currentDirectoryURL` affects the launched child process,
  which is exactly what we want here.
- Setting CWD to the app directory is low risk because the executable is also
  resolved from that same directory in the file-sync path.
- The change should not affect Linux or Docker flows because they do not use
  this native `Foundation.Process` launch path.

## Acceptance criteria

- A macOS app launched via the file-sync path starts with
  `<appsBase>/<appID>` as its CWD
- Relative path reads from the synced app directory work as expected
- There is automated Swift test coverage proving the launched process sees that
  directory as its working directory on both the normal and sandboxed
  file-sync native launch paths
- Legacy OCI / `imageName` native launch behavior is unchanged with respect to
  CWD
- Fallback `--appPath` behavior remains unchanged
