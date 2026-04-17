# Swift/macOS CI plan

## Decisions

- Use **one full Swift/macOS validation path everywhere**. Do not distinguish between PR and main.
- Use **`macos-26`** for all Swift/macOS CI jobs.
- Run the full path whenever Swift-relevant files change:
  - `swift/**`
  - `Proto/**`
  - `.github/workflows/**`
- Treat Swift package tests and the macOS app release build as **required**.
- Retain the packaged macOS release app in GitHub Actions as a downloadable artifact.
- Add a **non-blocking placeholder Slack hook** after a successful artifact upload.

## What should run

### 1. Swift package tests

Run the shared package tests on macOS:

```bash
cd swift/WendyAgentCore
swift test
```

Why:

- This is the highest-signal validation for `WendyAgentCore`.
- The package already has meaningful test coverage.
- The package is macOS-only, so macOS CI is the right execution environment.

### 2. Release macOS app build

Always build the real Xcode workspace and app scheme in **Release**:

```bash
cd swift
xcodebuild build \
  -workspace WendyAgent.xcworkspace \
  -scheme WendyAgentMac \
  -configuration Release \
  -destination 'platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -skipMacroValidation
```

Notes:

- The app currently uses manual signing settings, so CI should explicitly disable signing.
- Build a **universal** app so the retained artifact is broadly useful.
- Validate the real workspace integration rather than only the package.

### 3. Ad-hoc signing for internal distribution artifact

After the Release build succeeds, ad-hoc sign the app before zipping it:

```bash
codesign --force --deep --sign - "<path-to-WendyAgentMac.app>"
```

Why:

- This keeps the artifact easy to use for internal testing.
- It avoids requiring distribution certificates in CI.
- It matches the intended Slack message of "Ad-hoc macOS build ready".

### 4. Package and upload artifact

Zip the built `.app` and upload it with a stable name:

```text
wendy-agent-macos-universal-<version>.zip
```

Initial retention recommendation:

- **14 days**

Upload requirements:

- use `actions/upload-artifact@v4`
- fail if the archive is missing
- surface the artifact name in the workflow summary and Slack placeholder

## Version and artifact naming

Use a CI version string derived from:

- base version: `1.0.0`
- branch name: sanitized Git ref name
- run number: `github.run_number`

Example:

```text
1.0.0-kb-wendy-agent-macos-release.123
```

Example artifact:

```text
wendy-agent-macos-universal-1.0.0-kb-wendy-agent-macos-release.123.zip
```

Recommended computed values:

- `VERSION`
- `BRANCH_NAME`
- `SHORT_SHA`
- `ARTIFACT_NAME`
- `RUN_URL`

`RUN_URL` should be:

```text
https://github.com/<owner>/<repo>/actions/runs/<run_id>
```

## Slack placeholder hook

Add a follow-up job or step that runs after artifact upload succeeds.

Policy:

- non-blocking
- only posts when the build and upload succeeded
- uses a webhook secret if present
- otherwise logs the message body to stdout as a placeholder

Initial message shape:

```text
- Ad-hoc macOS build ready
- Version: 1.0.0-kb-wendy-agent-macos-release.123
- Branch: kb.wendy-agent-macos-release
- Commit: abc1234
- Download: <workflow run URL>
- Artifact: wendy-agent-macos-universal-1.0.0-kb-wendy-agent-macos-release.123.zip
```

Recommendation:

- link to the **workflow run URL**, not a direct artifact URL
- include the artifact filename exactly so it is easy to find in the run

## Caching

Use cache only for package resolution initially.

Cache target:

- cloned Swift package sources resolved from the workspace/package

Cache key inputs:

- runner OS
- Xcode version
- `swift/WendyAgentCore/Package.resolved`

Do **not** cache full `DerivedData` initially.

Why:

- package dependency caching gives most of the win
- full `DerivedData` is large and brittle across Xcode updates

## Xcode strategy

- Pin a specific Xcode version compatible with Swift 6.2.
- Do not rely on whatever happens to be the default on `macos-26`.
- Keep the runner fixed at `macos-26` unless CI stability forces a fallback.

## Gating and failure policy

Required:

- Swift package tests
- Release universal app build
- artifact packaging/upload

Non-blocking:

- Slack placeholder notification

Failure policy:

- if tests fail, fail the workflow
- if the Release app build fails, fail the workflow
- if the archive cannot be created or uploaded, fail the workflow
- if Slack notification fails, do not fail the workflow

## Current gaps this closes

This plan closes the following current gaps:

- no Swift CI coverage for `WendyAgentCore`
- no Xcode app validation for `WendyAgentMac`
- no retained macOS build artifact for reviewers or testers
- no notification hook for internal distribution of CI app builds

## Incremental rollout

### Phase 1: add the unified workflow

Add a new workflow file:

- `.github/workflows/swift-macos.yml`

Jobs:

1. `prepare`
   - compute version metadata and artifact names
2. `swift-tests`
   - run `swift test`
3. `build-macos-release`
   - build Release universal app
   - ad-hoc sign
   - zip artifact
   - upload artifact
4. `notify-slack`
   - placeholder webhook post or log output
   - non-blocking

### Phase 2: integrate with branch protection

Mark the unified workflow's required validations as merge-blocking for Swift-relevant changes.

### Phase 3: optional quality additions later

After the core workflow is stable, consider:

- `swift-format` check
- a small `WendyAgentMac` test target for non-AppKit logic
- optional unsigned `.app` plus zipped archive metadata in the workflow summary

## Small reviewable file changes

### First change

- add `swift-macos-ci.plan.md`

### Next implementation change

- add `.github/workflows/swift-macos.yml`

### Later optional changes

- add `.swift-format`
- add macOS app tests under `swift/`

## Recommended first implementation scope

Implement only the following in the first CI change:

- macOS runner: `macos-26`
- one unified workflow for all Swift-relevant changes
- `swift test`
- Release universal app build
- ad-hoc signing
- zipped artifact upload with retention
- placeholder Slack hook

That gives a single, high-confidence path without splitting behavior by branch type.
