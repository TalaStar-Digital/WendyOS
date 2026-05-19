import Foundation
import Subprocess

#if canImport(WinSDK)
    @preconcurrency import WinSDK
#endif

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

public actor WendyE2ESession {
    public nonisolated let machine: WendyE2EMachine
    public nonisolated let workingDirectory: String?
    public nonisolated let env: [String: String]

    public nonisolated var wendyCacheDirectory: String {
        let homeDirectory =
            self.env["HOME"].flatMap(Self.nonEmpty)
            ?? Self.defaultHomeDirectory(
                for: self.machine
            )

        switch self.machine.os {
        case .macOS:
            return Self.path(homeDirectory, "Library", "Caches", "wendy")
        case .linux, .wendyOS:
            let cacheHome =
                self.env["XDG_CACHE_HOME"].flatMap(Self.nonEmpty)
                ?? Self.path(homeDirectory, ".cache")
            return Self.path(cacheHome, "wendy")
        case .windows:
            let localAppData =
                self.env["LOCALAPPDATA"].flatMap(Self.nonEmpty)
                ?? Self.path(homeDirectory, "AppData", "Local")
            return Self.path(localAppData, "wendy")
        }
    }

    // MARK: - Beginning and Ending Sessions

    public static func begin(
        for machine: WendyE2EMachine,
        workingDirectory: String? = nil,
        env: [String: String] = [:],
        resetDirectoriesOnFirstCommand: Bool = false,
        verbose: Bool = false,
        recorder: WendyE2ERecorder? = nil
    ) async throws -> WendyE2ESession {
        let session = WendyE2ESession(
            machine: machine,
            workingDirectory: workingDirectory,
            env: env,
            resetDirectoriesOnFirstCommand: resetDirectoriesOnFirstCommand,
            recorder: recorder,
            verbose: verbose || WendyE2EEnvironment.verbose
        )

        return session
    }

    public func end() async throws {
        // Intentionally a no-op for now. This is the future hook for closing
        // persistent transports, PTYs, temp state, or other session resources.
    }

    public static func with<Result>(
        _ machine: WendyE2EMachine,
        body: @Sendable (WendyE2ESession) async throws -> Result
    ) async throws -> Result {
        var sessions: [WendyE2ESession] = []
        do {
            let session = try await Self.begin(for: machine)
            sessions.append(session)
            let result = try await body(session)
            try await Self.end(sessions)
            return result
        } catch {
            try? await Self.end(sessions)
            throw error
        }
    }

    public static func with<Result>(
        _ first: WendyE2EMachine,
        _ second: WendyE2EMachine,
        body: @Sendable (WendyE2ESession, WendyE2ESession) async throws -> Result
    ) async throws -> Result {
        var sessions: [WendyE2ESession] = []
        do {
            let firstSession = try await Self.begin(for: first)
            sessions.append(firstSession)
            let secondSession = try await Self.begin(for: second)
            sessions.append(secondSession)
            let result = try await body(firstSession, secondSession)
            try await Self.end(sessions)
            return result
        } catch {
            try? await Self.end(sessions)
            throw error
        }
    }

    public static func with<Result>(
        _ first: WendyE2EMachine,
        _ second: WendyE2EMachine,
        _ third: WendyE2EMachine,
        body: @Sendable (WendyE2ESession, WendyE2ESession, WendyE2ESession) async throws -> Result
    ) async throws -> Result {
        var sessions: [WendyE2ESession] = []
        do {
            let firstSession = try await Self.begin(for: first)
            sessions.append(firstSession)
            let secondSession = try await Self.begin(for: second)
            sessions.append(secondSession)
            let thirdSession = try await Self.begin(for: third)
            sessions.append(thirdSession)
            let result = try await body(firstSession, secondSession, thirdSession)
            try await Self.end(sessions)
            return result
        } catch {
            try? await Self.end(sessions)
            throw error
        }
    }

    // MARK: - Running Shell Commands

    public func posixShell(_ command: String) async throws -> WendyE2EShellResult {
        if self.verbose {
            Self.printCommand(machine: self.machine.name, command: command)
        }

        let resetDirectories = self.resetDirectoriesForNextCommand()
        let harnessPrefix = self.harnessPrefix(resetDirectories: resetDirectories)
        let invocation = self.invocation(for: command, harnessPrefix: harnessPrefix)

        return try await self.runShell(
            command: command,
            invocation: invocation,
            harnessPrefix: harnessPrefix,
            scriptShellName: Self.localShellName
        )
    }

    public func powerShell(_ command: String) async throws -> WendyE2EShellResult {
        if self.verbose {
            Self.printCommand(machine: self.machine.name, command: command)
        }

        let resetDirectories = self.resetDirectoriesForNextCommand()
        let harnessPrefix = self.powerShellHarnessPrefix(resetDirectories: resetDirectories)
        let invocation = try self.powerShellInvocation(for: command, harnessPrefix: harnessPrefix)

        return try await self.runShell(
            command: command,
            invocation: invocation,
            harnessPrefix: harnessPrefix,
            scriptShellName: Self.localPowerShellName
        )
    }

    public func sh(_ command: String) async throws {
        try await self.sh(posix: command, power: command)
    }

    public func sh<Result>(
        _ command: String,
        body: @Sendable (_ result: WendyE2EShellResult) async throws -> Result
    ) async throws -> Result {
        try await self.sh(posix: command, power: command, body: body)
    }

    public func sh(posix: String, power: String) async throws {
        let result = try await self.defaultShell(posix: posix, power: power)
        try result.requireSuccess()
    }

    public func sh<Result>(
        posix: String,
        power: String,
        body: @Sendable (_ result: WendyE2EShellResult) async throws -> Result
    ) async throws -> Result {
        try await body(try await self.defaultShell(posix: posix, power: power))
    }

    public func pty(_ command: String) async throws {
        try await self.pty(posix: command, power: command)
    }

    public func pty<Result>(
        _ command: String,
        body: @Sendable (_ result: WendyE2EShellResult) async throws -> Result
    ) async throws -> Result {
        try await self.pty(posix: command, power: command, body: body)
    }

    // WARNING: The POSIX PTY implementation currently shells out to `script`.
    // If parallel PTY runs become flaky/hang again, reintroduce the
    // process-wide serializer from
    // https://github.com/wendylabsinc/wendy-agent/commit/e8a448fa02e5d3ac9bf9c76282346e2092eab30a.
    public func pty(posix: String, power: String) async throws {
        try await self.sh(
            posix: Self.ptyPOSIXCommand(posix, os: self.machine.os),
            power: Self.ptyPowerShellCommand(power, os: self.machine.os)
        )
    }

    public func pty<Result>(
        posix: String,
        power: String,
        body: @Sendable (_ result: WendyE2EShellResult) async throws -> Result
    ) async throws -> Result {
        try await self.sh(
            posix: Self.ptyPOSIXCommand(posix, os: self.machine.os),
            power: Self.ptyPowerShellCommand(power, os: self.machine.os),
            body: body
        )
    }

    // MARK: - Internal

    private init(
        machine: WendyE2EMachine,
        workingDirectory: String? = nil,
        env: [String: String] = [:],
        resetDirectoriesOnFirstCommand: Bool = false,
        recorder: WendyE2ERecorder? = nil,
        verbose: Bool = false
    ) {
        precondition(workingDirectory?.isEmpty != true, "workingDirectory must not be empty")
        for key in env.keys {
            precondition(
                Self.isValidEnvironmentKey(key),
                "env keys must be valid shell variable names"
            )
        }

        self.machine = machine
        self.workingDirectory =
            workingDirectory ?? (machine.isLocal ? FileManager.default.currentDirectoryPath : nil)
        self.env = env
        self.resetDirectoriesOnFirstCommand = resetDirectoriesOnFirstCommand
        self.recorder = recorder
        self.verbose = verbose
    }

    // MARK: - Private

    private let resetDirectoriesOnFirstCommand: Bool
    private var didRunCommand = false
    private let recorder: WendyE2ERecorder?
    private let verbose: Bool

    private static func end(_ sessions: [WendyE2ESession]) async throws {
        for session in sessions.reversed() {
            try await session.end()
        }
    }

    private func resetDirectoriesForNextCommand() -> Bool {
        defer { self.didRunCommand = true }
        return self.resetDirectoriesOnFirstCommand && !self.didRunCommand
    }

    private func defaultShell(posix: String, power: String) async throws -> WendyE2EShellResult {
        switch self.machine.os {
        case .windows:
            try await self.powerShell(power)
        case .macOS, .linux, .wendyOS:
            try await self.posixShell(posix)
        }
    }

    private static func ptyPOSIXCommand(_ command: String, os: WendyE2EMachineOS) -> String {
        switch os {
        case .macOS:
            return "script -q /dev/null sh -c \(Self.shellQuote(command))"
        case .linux, .wendyOS:
            return "script -q -c \(Self.shellQuote(command)) /dev/null"
        case .windows:
            return command
        }
    }

    private static func ptyPowerShellCommand(_ command: String, os: WendyE2EMachineOS) -> String {
        switch os {
        case .windows:
            return "throw 'PTY execution is not supported on Windows yet.'"
        case .macOS, .linux, .wendyOS:
            return command
        }
    }

    private func runShell(
        command: String,
        invocation: Invocation,
        harnessPrefix: [String],
        scriptShellName: String
    ) async throws -> WendyE2EShellResult {
        let start = ContinuousClock.now
        let record = try await Self.invoke(invocation)
        let duration = start.duration(to: .now)

        self.recorder?.record(
            session: self,
            command: command,
            processID: record.processIdentifier,
            status: String(describing: record.terminationStatus),
            duration: duration,
            standardOutput: record.standardOutput,
            standardError: record.standardError,
            harnessPrefix: harnessPrefix,
            scriptShellName: scriptShellName
        )

        return WendyE2EShellResult(
            machine: self.machine,
            command: command,
            processID: record.processIdentifier,
            status: WendyE2EShellStatus(record.terminationStatus),
            duration: duration,
            stdout: record.standardOutput,
            stderr: record.standardError
        )
    }

    private func invocation(for command: String, harnessPrefix: [String]) -> Invocation {
        if self.machine.isLocal {
            return self.localInvocation(for: command, harnessPrefix: harnessPrefix)
        }

        return self.sshInvocation(for: command, harnessPrefix: harnessPrefix)
    }

    private func localInvocation(for command: String, harnessPrefix: [String]) -> Invocation {
        Invocation(
            executable: Self.localShellPath,
            arguments: ["-lc", self.wrapped(command, harnessPrefix: harnessPrefix)],
            environment: .inherit,
            workingDirectory: nil
        )
    }

    private func sshInvocation(for command: String, harnessPrefix: [String]) -> Invocation {
        let wrappedCommand = self.wrapped(command, harnessPrefix: harnessPrefix)
        let loginShellCommand = "exec \"${SHELL:-/bin/sh}\" -lc \(Self.shellQuote(wrappedCommand))"

        return Invocation(
            executable: Self.localSSHPath,
            arguments: [
                "-o",
                "BatchMode=yes",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-o",
                "LogLevel=ERROR",
                "-T",
                self.sshTarget(address: self.machine.address),
                loginShellCommand,
            ],
            environment: .inherit,
            workingDirectory: nil
        )
    }

    private func powerShellInvocation(
        for command: String,
        harnessPrefix: [String]
    ) throws
        -> Invocation
    {
        guard self.machine.isLocal else {
            throw WendyE2EMachineError.powerShellUnavailable(machine: self.description)
        }

        return Invocation(
            executable: try Self.localPowerShellPath(machine: self.description),
            arguments: [
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                self.powerShellWrapped(command, harnessPrefix: harnessPrefix),
            ],
            environment: .inherit,
            workingDirectory: nil
        )
    }

    private static var localShellPath: String {
        let environmentShell = ProcessInfo.processInfo.environment["SHELL"]
            .flatMap(Self.nonEmpty)

        #if os(Windows)
            if let environmentShell, Self.isPOSIXCompatibleShell(environmentShell) {
                return environmentShell
            }
            if let shell = Self.findExecutable(named: ["sh.exe", "bash.exe", "sh", "bash"]) {
                return shell
            }
            if let shell = Self.firstExecutablePath(
                [
                    "C:\\msys64\\usr\\bin\\sh.exe",
                    "C:\\Program Files\\Git\\usr\\bin\\sh.exe",
                    "C:\\Program Files\\Git\\bin\\sh.exe",
                ]
            ) {
                return shell
            }
        #endif

        let normalizedShell = environmentShell ?? "/bin/sh"
        Self.preconditionPOSIXCompatibleShell(normalizedShell)
        return normalizedShell
    }

    private static var localShellName: String {
        let name = Self.lastPathComponent(Self.localShellPath)
        return name.isEmpty ? "sh" : name
    }

    private static var localPowerShellName: String {
        let name = (try? Self.localPowerShellPath()).map {
            URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent
        }
        return name.flatMap(Self.nonEmpty) ?? "pwsh"
    }

    private static func localPowerShellPath(
        machine: String = WendyE2EMachine.current.description
    ) throws -> String {
        let candidates = ["pwsh", "pwsh.exe", "powershell", "powershell.exe"]
        guard let path = Self.findExecutable(named: candidates) else {
            throw WendyE2EMachineError.powerShellUnavailable(machine: machine)
        }
        return path
    }

    private static var localSSHPath: String {
        Self.findExecutable(named: ["ssh", "ssh.exe"]) ?? "/usr/bin/ssh"
    }

    private static func preconditionPOSIXCompatibleShell(_ shell: String) {
        precondition(
            Self.isPOSIXCompatibleShell(shell),
            """
            Wendy E2E tests require SHELL to be a POSIX-compatible shell.
            Unsupported SHELL: \(shell)
            Use sh, bash, zsh, dash, or ksh. For example:
              export SHELL=/bin/zsh
            Then rerun the E2E command.
            """
        )
    }

    private static func isPOSIXCompatibleShell(_ shell: String) -> Bool {
        let shellName = Self.lastPathComponent(shell).lowercased()
        let unsupportedShells: Set<String> = [
            "csh", "fish", "pwsh", "pwsh.exe", "powershell", "powershell.exe", "tcsh",
        ]
        return !unsupportedShells.contains(shellName)
    }

    private static func lastPathComponent(_ path: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\")
        return path.trimmingCharacters(in: separators)
            .components(separatedBy: separators)
            .last ?? ""
    }

    private func harnessPrefix(resetDirectories: Bool) -> [String] {
        var parts = self.env.keys.sorted().map { key in
            "export \(key)=\(Self.shellEnvironmentValue(self.env[key] ?? ""))"
        }

        let setupDirectories = self.setupDirectories()
        if resetDirectories, !setupDirectories.isEmpty {
            parts.append(
                "rm -rf "
                    + setupDirectories
                    .map(self.shellPathValue)
                    .joined(separator: " ")
            )
        }

        if !setupDirectories.isEmpty {
            parts.append(
                "mkdir -p "
                    + setupDirectories
                    .map(self.shellPathValue)
                    .joined(separator: " ")
            )
        }

        if let workingDirectory = self.workingDirectory {
            parts.append("cd \(self.shellPathValue(workingDirectory))")
        }

        return parts
    }

    private func powerShellHarnessPrefix(resetDirectories: Bool) -> [String] {
        var parts = self.env.keys.sorted().map { key in
            "$env:\(key) = \(Self.powerShellEnvironmentValue(self.env[key] ?? ""))"
        }

        let setupDirectories = self.setupDirectories()
        if resetDirectories {
            parts.append(
                contentsOf: setupDirectories.map { directory in
                    "Remove-Item -LiteralPath \(self.powerShellPathValue(directory)) -Recurse -Force -ErrorAction SilentlyContinue"
                }
            )
        }

        parts.append(
            contentsOf: setupDirectories.map { directory in
                "New-Item -ItemType Directory -Force -Path \(self.powerShellPathValue(directory)) | Out-Null"
            }
        )

        if let workingDirectory = self.workingDirectory {
            parts.append(
                "Set-Location -LiteralPath \(self.powerShellPathValue(workingDirectory))"
            )
        }

        return parts
    }

    private func shellPathValue(_ path: String) -> String {
        guard let reference = self.environmentPathReference(for: path) else {
            return Self.shellEnvironmentValue(path)
        }

        switch reference.suffix {
        case "":
            return "$\(reference.name)"
        case let suffix where Self.isShellSafePathSuffix(suffix):
            return "$\(reference.name)\(suffix)"
        default:
            return "$\(reference.name)\(Self.shellQuote(reference.suffix))"
        }
    }

    private func powerShellPathValue(_ path: String) -> String {
        guard let reference = self.environmentPathReference(for: path) else {
            return Self.powerShellEnvironmentValue(path)
        }

        switch reference.suffix {
        case "":
            return "$env:\(reference.name)"
        default:
            return
                "(Join-Path $env:\(reference.name) \(Self.powerShellQuote(String(reference.suffix.dropFirst()))))"
        }
    }

    private func environmentPathReference(for path: String) -> (name: String, suffix: String)? {
        self.env
            .filter { key, value in
                Self.isValidEnvironmentName(key) && !value.isEmpty && !value.contains("$")
            }
            .sorted { lhs, rhs in lhs.value.count > rhs.value.count }
            .compactMap { key, value -> (name: String, suffix: String)? in
                if path == value {
                    return (key, "")
                }

                let base = Self.trimmingTrailingPathSeparators(value)
                for separator in ["/", "\\"] {
                    let prefix = base + separator
                    if path.hasPrefix(prefix) {
                        return (key, String(path.dropFirst(base.count)))
                    }
                }

                return nil
            }
            .first
    }

    private func setupDirectories() -> [String] {
        var directories: [String] = []
        var seen: Set<String> = []

        func append(_ directory: String?) {
            guard let directory, !directory.isEmpty, seen.insert(directory).inserted else {
                return
            }
            directories.append(directory)
        }

        append(self.env["HOME"])
        append(self.env["TMPDIR"])
        append(self.workingDirectory)

        return directories
    }

    private func wrapped(_ command: String, harnessPrefix: [String]) -> String {
        (harnessPrefix + [command]).joined(separator: " && ")
    }

    private func powerShellWrapped(_ command: String, harnessPrefix: [String]) -> String {
        (["$ErrorActionPreference = 'Stop'"] + harnessPrefix + [command]).joined(separator: "\n")
    }

    private func sshTarget(address: String) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return self.machine.user.map { "\($0)@\(host)" } ?? host
    }

    private static func defaultHomeDirectory(for machine: WendyE2EMachine) -> String {
        if machine.isLocal {
            FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            "$HOME"
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func path(_ first: String, _ rest: String...) -> String {
        rest.reduce(first) { path, component in
            let suffix = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.hasSuffix("/") ? "\(path)\(suffix)" : "\(path)/\(suffix)"
        }
    }

    private static func trimmingTrailingPathSeparators(_ value: String) -> String {
        var result = value
        while result.count > 1 && (result.hasSuffix("/") || result.hasSuffix("\\")) {
            result.removeLast()
        }
        return result
    }

    private static func isShellSafePathSuffix(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                scalar == "/" || scalar == "." || scalar == "_" || scalar == "-"
                    || CharacterSet.alphanumerics.contains(scalar)
            }
    }

    private static func shellEnvironmentValue(_ value: String) -> String {
        var parts: [String] = []
        var literal = ""
        var index = value.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else {
                return
            }
            parts.append(Self.shellQuote(literal))
            literal = ""
        }

        while index < value.endIndex {
            guard value[index] == "$" else {
                literal.append(value[index])
                index = value.index(after: index)
                continue
            }

            let next = value.index(after: index)
            guard next < value.endIndex else {
                literal.append(value[index])
                index = next
                continue
            }

            if value[next] == "{" {
                guard let close = value[next...].firstIndex(of: "}") else {
                    literal.append(value[index])
                    index = next
                    continue
                }

                let nameStart = value.index(after: next)
                let name = String(value[nameStart..<close])
                guard Self.isValidEnvironmentName(name) else {
                    literal.append(value[index])
                    index = next
                    continue
                }

                flushLiteral()
                parts.append("${\(name)}")
                index = value.index(after: close)
                continue
            }

            guard Self.isEnvironmentNameStart(value[next]) else {
                literal.append(value[index])
                index = next
                continue
            }

            var end = value.index(after: next)
            while end < value.endIndex, Self.isEnvironmentNameBody(value[end]) {
                end = value.index(after: end)
            }

            flushLiteral()
            parts.append("$\(String(value[next..<end]))")
            index = end
        }

        flushLiteral()
        return parts.isEmpty ? "''" : parts.joined()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func powerShellEnvironmentValue(_ value: String) -> String {
        var parts: [String] = []
        var literal = ""
        var index = value.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else {
                return
            }
            parts.append(Self.powerShellQuote(literal))
            literal = ""
        }

        while index < value.endIndex {
            guard value[index] == "$" else {
                literal.append(value[index])
                index = value.index(after: index)
                continue
            }

            let next = value.index(after: index)
            guard next < value.endIndex else {
                literal.append(value[index])
                index = next
                continue
            }

            if value[next] == "{" {
                guard let close = value[next...].firstIndex(of: "}") else {
                    literal.append(value[index])
                    index = next
                    continue
                }

                let nameStart = value.index(after: next)
                let name = String(value[nameStart..<close])
                guard Self.isValidEnvironmentName(name) else {
                    literal.append(value[index])
                    index = next
                    continue
                }

                flushLiteral()
                parts.append("$env:\(name)")
                index = value.index(after: close)
                continue
            }

            guard Self.isEnvironmentNameStart(value[next]) else {
                literal.append(value[index])
                index = next
                continue
            }

            var end = value.index(after: next)
            while end < value.endIndex, Self.isEnvironmentNameBody(value[end]) {
                end = value.index(after: end)
            }

            flushLiteral()
            parts.append("$env:\(String(value[next..<end]))")
            index = end
        }

        flushLiteral()
        return parts.isEmpty ? "''" : parts.joined(separator: " + ")
    }

    private static func powerShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func firstExecutablePath(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func findExecutable(named candidates: [String]) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let pathValue = environment["PATH"] ?? environment["Path"] ?? environment["path"] ?? ""
        let pathSeparator: Character
        #if os(Windows)
            pathSeparator = ";"
        #else
            pathSeparator = ":"
        #endif

        for directory in pathValue.split(separator: pathSeparator, omittingEmptySubsequences: false)
        {
            let directoryPath = directory.isEmpty ? "." : String(directory)
            for candidate in candidates {
                let path = Self.executablePath(directory: directoryPath, candidate: candidate)
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        return nil
    }

    private static func executablePath(directory: String, candidate: String) -> String {
        if directory.hasSuffix("/") || directory.hasSuffix("\\") {
            return "\(directory)\(candidate)"
        }

        #if os(Windows)
            return "\(directory)\\\(candidate)"
        #else
            return "\(directory)/\(candidate)"
        #endif
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.first else {
            return false
        }
        guard first == "_" || first.isASCII && first.isLetter else {
            return false
        }

        return key.dropFirst().allSatisfy { character in
            character == "_" || character.isASCII && (character.isLetter || character.isNumber)
        }
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.first else {
            return false
        }
        return Self.isEnvironmentNameStart(first)
            && name.dropFirst().allSatisfy(Self.isEnvironmentNameBody)
    }

    private static func isEnvironmentNameStart(_ character: Character) -> Bool {
        character == "_" || character.isASCII && character.isLetter
    }

    private static func isEnvironmentNameBody(_ character: Character) -> Bool {
        character == "_" || character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func printCommand(machine: String, command: String) {
        Self.printToStandardError("[\(machine)] $ \(command)\n")
    }

    private static func printToStandardError(_ message: String) {
        _ = try? FileDescriptor.standardError.writeAll(message.utf8)
    }

    private static func outputDescription(_ output: some Sendable) -> String {
        let value = output as Any
        if let string = value as? String {
            return string
        }

        if let string = value as? String? {
            return string ?? ""
        }

        return String(describing: value)
    }

    private static func invoke(_ invocation: Invocation) async throws -> StringExecutionRecord {
        #if os(Windows)
            try self.invokeWithWinSDK(invocation)
        #else
            let record = try await Subprocess.run(
                .path(FilePath(invocation.executable)),
                arguments: Arguments(invocation.arguments),
                environment: invocation.environment,
                workingDirectory: invocation.workingDirectory,
                output: StringOutput<UTF8>.string(limit: .max),
                error: StringOutput<UTF8>.string(limit: .max)
            )

            return StringExecutionRecord(
                processIdentifier: String(describing: record.processIdentifier),
                terminationStatus: record.terminationStatus,
                standardOutput: record.standardOutput ?? "",
                standardError: record.standardError ?? ""
            )
        #endif
    }

    #if os(Windows)
        private static func invokeWithWinSDK(
            _ invocation: Invocation
        ) throws
            -> StringExecutionRecord
        {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory.appendingPathComponent(
                "wendy-e2e-subprocess-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }

            let stdoutURL = directory.appendingPathComponent("stdout.txt", isDirectory: false)
            let stderrURL = directory.appendingPathComponent("stderr.txt", isDirectory: false)

            let stdoutHandle = try Self.createInheritedOutputHandle(path: stdoutURL.path)
            let stderrHandle = try Self.createInheritedOutputHandle(path: stderrURL.path)
            var outputHandlesClosed = false
            defer {
                if !outputHandlesClosed {
                    CloseHandle(stdoutHandle)
                    CloseHandle(stderrHandle)
                }
            }

            var startupInfo = STARTUPINFOW()
            startupInfo.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
            startupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startupInfo.hStdInput = GetStdHandle(DWORD(STD_INPUT_HANDLE))
            startupInfo.hStdOutput = stdoutHandle
            startupInfo.hStdError = stderrHandle

            var processInfo = PROCESS_INFORMATION()
            var commandLine =
                Array(
                    Self.windowsCommandLine(
                        executable: invocation.executable,
                        arguments: invocation.arguments
                    ).utf16
                ) + [0]

            let created = try invocation.executable.withCString(encodedAs: UTF16.self) { appName in
                try commandLine.withUnsafeMutableBufferPointer { commandLineBuffer in
                    try Self.withOptionalWindowsString(
                        invocation.workingDirectory.map { String(describing: $0) }
                    ) { workingDirectory in
                        CreateProcessW(
                            appName,
                            commandLineBuffer.baseAddress,
                            nil,
                            nil,
                            true,
                            0,
                            nil,
                            workingDirectory,
                            &startupInfo,
                            &processInfo
                        )
                    }
                }
            }

            guard created else {
                throw Self.windowsProcessError("CreateProcessW failed")
            }
            defer {
                CloseHandle(processInfo.hThread)
                CloseHandle(processInfo.hProcess)
            }

            WaitForSingleObject(processInfo.hProcess, INFINITE)

            var exitCode: DWORD = 1
            guard GetExitCodeProcess(processInfo.hProcess, &exitCode) else {
                throw Self.windowsProcessError("GetExitCodeProcess failed")
            }

            CloseHandle(stdoutHandle)
            CloseHandle(stderrHandle)
            outputHandlesClosed = true

            let stdout = try String(decoding: Data(contentsOf: stdoutURL), as: UTF8.self)
            let stderr = try String(decoding: Data(contentsOf: stderrURL), as: UTF8.self)

            return StringExecutionRecord(
                processIdentifier: String(processInfo.dwProcessId),
                terminationStatus: .exited(TerminationStatus.Code(exitCode)),
                standardOutput: stdout,
                standardError: stderr
            )
        }

        private static func createInheritedOutputHandle(path: String) throws -> HANDLE {
            var security = SECURITY_ATTRIBUTES(
                nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                lpSecurityDescriptor: nil,
                bInheritHandle: true
            )

            let handle = path.withCString(encodedAs: UTF16.self) { pathPointer in
                CreateFileW(
                    pathPointer,
                    DWORD(GENERIC_WRITE),
                    DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                    &security,
                    DWORD(CREATE_ALWAYS),
                    DWORD(FILE_ATTRIBUTE_NORMAL),
                    nil
                )
            }

            guard let handle, handle != INVALID_HANDLE_VALUE else {
                throw Self.windowsProcessError("CreateFileW failed")
            }

            return handle
        }

        private static func withOptionalWindowsString<Result>(
            _ value: String?,
            _ body: (UnsafePointer<WCHAR>?) throws -> Result
        ) throws -> Result {
            guard let value else {
                return try body(nil)
            }

            return try value.withCString(encodedAs: UTF16.self, body)
        }

        private static func windowsProcessError(_ message: String) -> NSError {
            NSError(
                domain: "WendyE2ETesting.WindowsProcess",
                code: Int(GetLastError()),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        private static func windowsCommandLine(executable: String, arguments: [String]) -> String {
            ([executable] + arguments).map(Self.windowsCommandLineQuote).joined(separator: " ")
        }

        private static func windowsCommandLineQuote(_ argument: String) -> String {
            guard !argument.isEmpty else {
                return "\"\""
            }

            if argument.unicodeScalars.allSatisfy({ scalar in
                scalar.value != 0x20 && scalar.value != 0x09 && scalar.value != 0x22
            }) {
                return argument
            }

            var quoted = "\""
            var backslashes = 0
            for character in argument {
                if character == "\\" {
                    backslashes += 1
                } else if character == "\"" {
                    quoted += String(repeating: "\\", count: backslashes * 2 + 1)
                    quoted.append(character)
                    backslashes = 0
                } else {
                    quoted += String(repeating: "\\", count: backslashes)
                    quoted.append(character)
                    backslashes = 0
                }
            }
            quoted += String(repeating: "\\", count: backslashes * 2)
            quoted.append("\"")
            return quoted
        }
    #endif
}

private struct StringExecutionRecord: Sendable {
    let processIdentifier: String
    let terminationStatus: TerminationStatus
    let standardOutput: String
    let standardError: String
}

private struct Invocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: Subprocess.Environment
    let workingDirectory: FilePath?
}

// MARK: - CustomStringConvertible

extension WendyE2ESession: CustomStringConvertible {
    public nonisolated var description: String {
        self.machine.description
    }
}
