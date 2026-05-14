import Foundation
public import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

public struct Session: Sendable {
    public let machine: Machine

    // MARK: - Beginning and Ending Sessions

    public static func begin(
        for machine: Machine,
        verbose: Bool = false,
        recorder: Recorder? = nil
    ) async throws -> Session {
        let session = Session(
            machine: machine,
            recorder: recorder,
            verbose: verbose || Environment.verbose
        )

        return session
    }

    public func end() async throws {
        // Intentionally a no-op for now. This is the future hook for closing
        // persistent transports, PTYs, temp state, or other session resources.
    }

    public static func with<Result>(
        _ machine: Machine,
        body: @Sendable (Session) async throws -> Result
    ) async throws -> Result {
        var sessions: [Session] = []
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
        _ first: Machine,
        _ second: Machine,
        body: @Sendable (Session, Session) async throws -> Result
    ) async throws -> Result {
        var sessions: [Session] = []
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
        _ first: Machine,
        _ second: Machine,
        _ third: Machine,
        body: @Sendable (Session, Session, Session) async throws -> Result
    ) async throws -> Result {
        var sessions: [Session] = []
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

    public func sh(_ command: String) async throws {
        let record = try await self.sh(
            command,
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        guard record.terminationStatus.isSuccess else {
            throw MachineError.commandFailed(
                machine: self.description,
                command: command,
                terminationStatus: record.terminationStatus
            )
        }
    }

    public func sh<Output: OutputProtocol, Error: ErrorOutputProtocol>(
        _ command: String,
        output: Output,
        error: Error = .discarded
    ) async throws -> ExecutionRecord<Output, Error> {
        if self.verbose {
            Self.printCommand(machine: self.machine.name, command: command)
        }

        let harnessPrefix = self.harnessPrefix()
        let invocation = self.invocation(for: command, harnessPrefix: harnessPrefix)

        let start = ContinuousClock.now
        let record = try await Self.invoke(
            invocation,
            output: output,
            error: error
        )
        let duration = start.duration(to: .now)

        self.recorder?.record(
            session: self,
            command: command,
            processIdentifier: String(describing: record.processIdentifier),
            terminationStatus: String(describing: record.terminationStatus),
            duration: duration,
            standardOutput: Self.outputDescription(record.standardOutput),
            standardError: Self.outputDescription(record.standardError),
            harnessPrefix: harnessPrefix,
            scriptShellName: Self.localShellName
        )

        return record
    }

    public func sh<Result>(
        _ command: String,
        output: StringOutput<UTF8> = .string(limit: .max),
        error: StringOutput<UTF8> = .string(limit: .max),
        body: @Sendable (_ standardOutput: String, _ standardError: String) async throws -> Result
    ) async throws -> Result {
        let record = try await self.sh(
            command,
            output: output,
            error: error
        )

        guard record.terminationStatus.isSuccess else {
            throw MachineError.commandFailed(
                machine: self.description,
                command: command,
                terminationStatus: record.terminationStatus
            )
        }

        return try await body(
            record.standardOutput ?? "",
            record.standardError ?? ""
        )
    }

    public func sh<Result>(
        _ command: String,
        output: StringOutput<UTF8> = .string(limit: .max),
        error: StringOutput<UTF8> = .string(limit: .max),
        body:
            @Sendable (
                _ terminationStatus: TerminationStatus,
                _ standardOutput: String,
                _ standardError: String
            ) async throws -> Result
    ) async throws -> Result {
        let record = try await self.sh(
            command,
            output: output,
            error: error
        )

        return try await body(
            record.terminationStatus,
            record.standardOutput ?? "",
            record.standardError ?? ""
        )
    }

    // MARK: - Internal

    private init(
        machine: Machine,
        recorder: Recorder? = nil,
        verbose: Bool = false
    ) {
        self.machine = machine
        self.recorder = recorder
        self.verbose = verbose
    }

    // MARK: - Private

    private let recorder: Recorder?
    private let verbose: Bool

    private static func end(_ sessions: [Session]) async throws {
        for session in sessions.reversed() {
            try await session.end()
        }
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
            executable: "/usr/bin/ssh",
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

    private static var localShellPath: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        let normalizedShell = shell.isEmpty ? "/bin/sh" : shell
        Self.preconditionPOSIXCompatibleShell(normalizedShell)
        return normalizedShell
    }

    private static var localShellName: String {
        let name = URL(fileURLWithPath: Self.localShellPath, isDirectory: false).lastPathComponent
        return name.isEmpty ? "sh" : name
    }

    private static func preconditionPOSIXCompatibleShell(_ shell: String) {
        let shellName = URL(fileURLWithPath: shell, isDirectory: false).lastPathComponent
            .lowercased()
        let unsupportedShells: Set<String> = ["csh", "fish", "pwsh", "powershell", "tcsh"]
        precondition(
            !unsupportedShells.contains(shellName),
            """
            Wendy E2E tests require SHELL to be a POSIX-compatible shell.
            Unsupported SHELL: \(shell)
            Use sh, bash, zsh, dash, or ksh. For example:
              export SHELL=/bin/zsh
            Then rerun the E2E command.
            """
        )
    }

    private func harnessPrefix() -> [String] {
        var parts = self.machine.env.keys.sorted().map { key in
            "export \(key)=\(Self.shellEnvironmentValue(self.machine.env[key] ?? ""))"
        }

        if let workingDirectory = self.machine.workingDirectory {
            parts.append("cd \(Self.shellQuote(workingDirectory))")
        }

        return parts
    }

    private func wrapped(_ command: String, harnessPrefix: [String]) -> String {
        (harnessPrefix + [command]).joined(separator: " && ")
    }

    private func sshTarget(address: String) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return self.machine.user.map { "\($0)@\(host)" } ?? host
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

    private static func invoke<Output: OutputProtocol, Error: ErrorOutputProtocol>(
        _ invocation: Invocation,
        output: Output,
        error: Error
    ) async throws -> ExecutionRecord<Output, Error> {
        try await Subprocess.run(
            .path(FilePath(invocation.executable)),
            arguments: Arguments(invocation.arguments),
            environment: invocation.environment,
            workingDirectory: invocation.workingDirectory,
            output: output,
            error: error
        )
    }
}

private struct Invocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: Subprocess.Environment
    let workingDirectory: FilePath?
}

// MARK: - CustomStringConvertible

extension Session: CustomStringConvertible {
    public var description: String {
        self.machine.description
    }
}
