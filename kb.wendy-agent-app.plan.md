# WendyAgent macOS app plan

## Goal

Turn the current Swift-based Wendy agent into a simple macOS menu bar app.

Keep this intentionally small:

- no main window
- no configuration UI
- no separate UI Swift package
- no CLI product
- no broad lifecycle abstraction layer

The first version should launch the agent automatically, live in the
menu bar, and provide a minimal menu with a quit action.

## Final shape

We only need two pieces:

1. **`WendyAgent` Swift package**
   - lives in `swift/`
   - is the shared core runtime
   - owns all agent behavior and service wiring
   - is exposed as a library product/module

2. **`WendyAgentApp` Xcode project**
   - lives in `swift/` alongside the package
   - owns the macOS menu bar UI and packaging
   - contains the app entry point, menu bar icon, error presentation,
     assets, and `Info.plist`

This is the whole plan. We are explicitly **not** creating a separate
`WendyAgentUI` target or package.

## Naming

Use these names consistently:

- Swift package name: `WendyAgent`
- Swift package library product/module: `WendyAgent`
- Xcode project name: `WendyAgentApp`
- Xcode app target name: `WendyAgentApp`
- app display name shown to users: `WendyAgent`

## Product behavior

The app should behave like this:

- user launches **WendyAgent**
- the agent starts automatically
- the app appears only as a menu bar item
- there is no main window
- clicking the menu bar item opens the menu
- the menu contains **Quit WendyAgent**

This should be a menu bar app configured as an `LSUIElement` app, so it:

- has no Dock icon
- does not behave like a normal foreground windowed app
- stays centered on the menu bar experience

## Startup and failure behavior

### Normal startup

On launch:

1. create the shared `Agent`
2. call `start()` automatically
3. show the normal menu bar icon

### Startup failure

If startup fails:

- keep the app alive
- show an error-badged menu bar icon
- show the error message in the menu
- keep **Quit WendyAgent** available

This avoids silent failure without requiring a full UI.

A first menu shape in the failed state is:

- error message text
- separator
- `Quit WendyAgent`

## Core package plan

### Objective

Refactor the current Swift code so the runtime lives in a library instead
of an `@main` CLI command.

### Public API

Keep the API deliberately tiny.

```swift
public struct AgentConfiguration: Sendable {
    public var port: Int = 50051
    public var otelPort: Int = 4317
    public var configDirectory: String = "/etc/wendy-agent"
    public var appPath: String = ""
    public var sandboxProfile: String = ""
}

public actor Agent {
    public init(configuration: AgentConfiguration = .init())
    public func start() async throws
    public func stop() async
}
```

That is enough for the app.

We do **not** need, yet:

- CLI-facing argument parsing
- event streams
- public runtime status models
- log streaming APIs
- generalized frontend-neutral abstractions

### Internals to preserve

The `WendyAgent` library should continue to own the existing runtime
behavior:

- logging bootstrap
- Docker detection and local registry startup
- gRPC server startup
- local OpenTelemetry receiver startup
- Bonjour advertising
- service group startup and shutdown
- existing service registration and wiring

### Source layout

Keep the core refactor minimal and close to the current layout.

```text
swift/
  Package.swift
  Sources/
    WendyAgent/
      Agent.swift
      AgentConfiguration.swift
      Docker/
      Services/
```

Guidelines:

- keep the package root in `swift/`
- keep `Sources/WendyAgent/` as the main source directory
- keep existing `Docker/` and `Services/` code in place as much as
  possible
- add only the minimum top-level files needed for the library boundary
- do not introduce extra architecture folders such as `Core/`,
  `Runtime/`, `Bootstrap/`, or `Internal/`

### Swift package manifest direction

`swift/Package.swift` should be simplified to match the new purpose:

- package name becomes `WendyAgent`
- expose a library product named `WendyAgent`
- drop the CLI executable product entirely
- keep generated gRPC/protobuf targets and tests

Conceptually:

```swift
products: [
    .library(name: "WendyAgent", targets: ["WendyAgent"]),
]
```

## Xcode app plan

### Objective

The Xcode app should be a simple, standard macOS app target that owns
all UI concerns.

### Location and layout

Keep the project inside `swift/` alongside the package.

Recommended shape:

```text
swift/
  WendyAgentApp.xcodeproj
  WendyAgentApp/
    WendyAgentApp.swift
    WendyAgentAppState.swift
    Assets.xcassets
    Info.plist
```

### Xcode-side code structure

Keep the app code tiny.

#### `WendyAgentApp.swift`

Responsibilities:

- `@main`
- declare the SwiftUI `MenuBarExtra`
- render normal vs error-badged icon
- render the menu contents
- connect the app state object to the menu UI

#### `WendyAgentAppState.swift`

This should be a small app-state object, not a large MVVM layer.

Responsibilities:

- own the shared `Agent`
- start it on launch
- handle quit
- expose a small renderable status for the menu bar UI

Use one small explicit status enum rather than loose booleans.

Conceptually:

```swift
enum AppStatus {
    case starting
    case running
    case failed(String)
}
```

This keeps the UI logic straightforward:

- `.starting` -> normal icon
- `.running` -> normal icon
- `.failed` -> badged icon + error text in menu

### UI technology

Use SwiftUI `MenuBarExtra`.

Reasoning:

- it is the smallest and most standard fit for this app
- the menu is tiny
- there is no window to manage
- there is no need for lower-level AppKit status-item plumbing yet

### `Info.plist`

Set the app up as an `LSUIElement` app so it behaves as a menu bar app
without a Dock icon.

## Icons and assets

## Source artwork

Use the Wendy mark from:

- `https://wendy.sh/layout/logo-icon.svg`

Keep editable source artwork in the repo if practical.

## Menu bar icon

Create a proper menu bar template icon:

- based on the Wendy logo mark
- monochrome only
- suitable for macOS template rendering
- visually crisp at small menu bar sizes

Also create an error-state variant by overlaying a simple red error badge
or exclamation mark on the normal icon.

## App icon

Create a separate app icon from the same Wendy mark.

Use the emerald palette already present in `go/internal/cli/tui/theme.go`:

- Emerald500: `#10b981`
- Emerald600: `#059669`
- Emerald700: `#047857`
- Emerald800: `#065f46`
- Emerald950: `#022c22`
- optional light accent: Emerald50 `#ecfdf5`

Icon direction:

- clean, functional first pass
- modern macOS app icon
- emerald-forward color treatment
- strong contrast and simple silhouette
- no overly elaborate rendering or visual effects

## Implementation phases

### Phase 1: convert the current CLI runtime into a library

Do the minimum necessary to turn the existing code into `WendyAgent`:

- remove the CLI `@main` role
- extract the runtime logic into `Agent`
- add `AgentConfiguration`
- keep service wiring behavior intact
- simplify `Package.swift` to a library-first package

### Phase 2: build the menu bar app in Xcode

Create or simplify the Xcode app inside `swift/` so it:

- imports `WendyAgent`
- uses `MenuBarExtra`
- starts the agent automatically
- presents failed startup in the menu bar
- quits cleanly by calling `Agent.stop()`

### Phase 3: add the app assets

Add:

- the monochrome menu bar template icon
- the error-badged menu bar icon
- the emerald app icon

Then wire them into the app target.

## Success criteria

This plan is successful when:

1. `swift/Package.swift` exposes `WendyAgent` as a library product
2. the core agent runtime lives in the `WendyAgent` Swift package
3. the CLI product is gone
4. the Xcode project lives in `swift/` alongside the package
5. launching the macOS app starts the agent automatically
6. the app appears only as a menu bar item
7. there is no main window or Dock icon
8. startup failures show an error-badged icon and a readable menu error
9. the menu includes `Quit WendyAgent`
10. quitting the app stops the agent cleanly
11. the app has a functional monochrome menu bar icon and an emerald app
    icon

## Guiding rule

When in doubt, choose the smaller design.

For this iteration, the right solution is the one with:

- fewer targets
- fewer public types
- minimal churn in the core package
- no separate UI package
- no window UI
- no abstraction created only for future possibilities
