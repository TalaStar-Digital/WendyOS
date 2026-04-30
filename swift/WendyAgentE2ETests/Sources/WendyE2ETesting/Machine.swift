import Darwin
import Foundation
public import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

public struct Machine: Sendable {
    public let name: String
    public let ssh: String?
    public let workingDirectory: String?
    public let verbose: Bool

    public var id: String {
        let location = self.ssh ?? "local"
        if let workingDirectory = self.workingDirectory {
            return "\(location):\(workingDirectory)"
        }

        return "\(location):~"
    }

    // MARK: - Creating Machines

    public init(
        name: String,
        ssh: String? = nil,
        workingDirectory: String? = nil,
        verbose: Bool = false,
        sshExecutable: String = "/usr/bin/ssh"
    ) {
        precondition(!name.isEmpty, "name must not be empty")
        precondition(ssh?.isEmpty != true, "ssh must not be empty")
        precondition(workingDirectory?.isEmpty != true, "workingDirectory must not be empty")
        precondition(!sshExecutable.isEmpty, "sshExecutable must not be empty")

        self.name = name
        self.ssh = ssh
        self.workingDirectory =
            workingDirectory ?? (ssh == nil ? FileManager.default.currentDirectoryPath : nil)
        self.verbose = verbose
        self.sshExecutable = sshExecutable
    }

    // MARK: - Running Commands

    public func run(
        _ command: String,
        filePath: String = #filePath,
        function: String = #function,
        line: Int = #line
    ) async throws {
        let outcome = try await self.run(
            command,
            filePath: filePath,
            function: function,
            line: line
        ) { _, _, stdout, stderr in
            if self.verbose {
                async let forwardStdout = Self.forward(stdout, to: .standardOutput, name: self.name)
                async let forwardStderr = Self.forward(stderr, to: .standardError, name: self.name)
                _ = try await (forwardStdout, forwardStderr)
            } else {
                async let discardStdout = Self.discard(stdout)
                async let discardStderr = Self.discard(stderr)
                _ = try await (discardStdout, discardStderr)
            }
        }

        guard outcome.terminationStatus.isSuccess else {
            throw MachineError.commandFailed(
                machine: self.description,
                command: command,
                terminationStatus: outcome.terminationStatus
            )
        }
    }

    public func run<Output: OutputProtocol, Error: ErrorOutputProtocol>(
        _ command: String,
        output: Output,
        error: Error = .discarded,
        filePath: String = #filePath,
        function: String = #function,
        line: Int = #line
    ) async throws -> ExecutionRecord<Output, Error> {
        if self.verbose {
            Self.printCommand(machine: self.name, command: command)
        }

        let invocation = self.invocation(for: command)
        let start = ContinuousClock.now
        let record = try await Self.invoke(
            invocation,
            output: output,
            error: error
        )
        let duration = start.duration(to: .now)

        Self.printExecutionReport(
            machine: self,
            command: command,
            filePath: filePath,
            function: function,
            line: line,
            processIdentifier: String(describing: record.processIdentifier),
            terminationStatus: String(describing: record.terminationStatus),
            duration: duration,
            standardOutput: Self.outputDescription(record.standardOutput),
            standardError: Self.outputDescription(record.standardError)
        )

        return record
    }

    public func run<Result>(
        _ command: String,
        output: StringOutput<UTF8> = .string(limit: .max),
        error: StringOutput<UTF8> = .string(limit: .max),
        filePath: String = #filePath,
        function: String = #function,
        line: Int = #line,
        body: @Sendable (_ standardOutput: String, _ standardError: String) async throws -> Result
    ) async throws -> Result {
        let record = try await self.run(
            command,
            output: output,
            error: error,
            filePath: filePath,
            function: function,
            line: line
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

    public func run<Result>(
        _ command: String,
        preferredBufferSize: Int? = nil,
        filePath: String = #filePath,
        function: String = #function,
        line: Int = #line,
        isolation: isolated (any Actor)? = #isolation,
        body:
            @Sendable (
                _ execution: Execution,
                _ inputWriter: StandardInputWriter,
                _ standardOutput: AsyncBufferSequence,
                _ standardError: AsyncBufferSequence
            ) async throws -> Result
    ) async throws -> ExecutionOutcome<Result> {
        if self.verbose {
            Self.printCommand(machine: self.name, command: command)
        }

        let invocation = self.invocation(for: command)
        let start = ContinuousClock.now
        let outcome = try await Subprocess.run(
            .path(FilePath(invocation.executable)),
            arguments: Arguments(invocation.arguments),
            environment: invocation.environment,
            workingDirectory: invocation.workingDirectory,
            preferredBufferSize: preferredBufferSize,
            isolation: isolation,
            body: body
        )
        let duration = start.duration(to: .now)

        Self.printExecutionReport(
            machine: self,
            command: command,
            filePath: filePath,
            function: function,
            line: line,
            processIdentifier: nil,
            terminationStatus: String(describing: outcome.terminationStatus),
            duration: duration,
            standardOutput: "<not captured: streaming API>",
            standardError: "<not captured: streaming API>"
        )

        return outcome
    }

    // MARK: - Private

    private let sshExecutable: String

    private func invocation(for command: String) -> Invocation {
        if let ssh = self.ssh {
            return Invocation(
                executable: self.sshExecutable,
                arguments: [
                    "-T",
                    ssh,
                    self.wrapped(command),
                ],
                environment: .inherit,
                workingDirectory: nil
            )
        }

        let user = Self.currentUser()
        return Invocation(
            executable: user.shell,
            arguments: ["-lc", command],
            environment: Self.loginEnvironment(for: user),
            workingDirectory: self.workingDirectory.map { FilePath($0) }
        )
    }

    private func wrapped(_ command: String) -> String {
        guard let workingDirectory = self.workingDirectory else {
            return command
        }

        return "cd \(Self.shellQuote(workingDirectory)) && \(command)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func currentUser() -> User {
        guard let entry = getpwuid(getuid()) else {
            let environment = ProcessInfo.processInfo.environment
            return User(
                name: environment["USER"] ?? "",
                home: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                shell: environment["SHELL"] ?? "/bin/sh"
            )
        }

        return User(
            name: String(cString: entry.pointee.pw_name),
            home: String(cString: entry.pointee.pw_dir),
            shell: String(cString: entry.pointee.pw_shell)
        )
    }

    private static func loginEnvironment(for user: User) -> Environment {
        .custom([
            "HOME": user.home,
            "LOGNAME": user.name,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": user.shell,
            "USER": user.name,
        ])
    }

    private static func printCommand(machine: String, command: String) {
        fputs("[\(machine)] $ \(command)\n", stderr)
    }

    private static func printExecutionReport(
        machine: Machine,
        command: String,
        filePath: String,
        function: String,
        line: Int,
        processIdentifier: String?,
        terminationStatus: String,
        duration: Duration,
        standardOutput: String,
        standardError: String
    ) {
        flockfile(stdout)
        defer { funlockfile(stdout) }

        print("""

            --- Wendy E2E command report ---
            Source: \(filePath):\(line)
            Function: \(function)
            Machine: \(machine.name)
            Machine ID: \(machine.id)
            SSH: \(machine.ssh ?? "<none>")
            Working directory: \(machine.workingDirectory ?? "<none>")
            Command: \(command)
            Process ID: \(processIdentifier ?? "<unavailable>")
            Termination status: \(terminationStatus)
            Duration: \(duration)

            stdout:
            \(standardOutput)

            stderr:
            \(standardError)
            --- End Wendy E2E command report ---
            """)
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

    private static func forward(
        _ sequence: AsyncBufferSequence,
        to handle: FileHandle,
        name: String
    ) async throws {
        for try await rawLine in sequence.lines() {
            let line = rawLine.trimmingCharacters(in: .newlines)
            try handle.write(contentsOf: Data("[\(name)] \(line)\n".utf8))
        }
    }

    private static func discard(_ sequence: AsyncBufferSequence) async throws {
        for try await _ in sequence {}
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
    let environment: Environment
    let workingDirectory: FilePath?
}

private struct User: Sendable {
    let name: String
    let home: String
    let shell: String
}

// MARK: - CustomStringConvertible

extension Machine: CustomStringConvertible {
    public var description: String {
        self.id
    }
}
