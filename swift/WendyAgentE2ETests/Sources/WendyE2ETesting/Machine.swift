import Darwin
import Foundation
import Subprocess

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
        self.workingDirectory = workingDirectory ?? (ssh == nil ? FileManager.default.currentDirectoryPath : nil)
        self.verbose = verbose
        self.sshExecutable = sshExecutable
    }

    // MARK: - Running Commands

    public func run(_ command: String) async throws {
        let outcome = try await self.run(command) { _, _, stdout, stderr in
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
        error: Error = .discarded
    ) async throws -> ExecutionRecord<Output, Error> {
        if self.verbose {
            Self.printCommand(machine: self.name, command: command)
        }

        let invocation = self.invocation(for: command)
        return try await Self.invoke(
            invocation,
            output: output,
            error: error
        )
    }

    public func run<Result>(
        _ command: String,
        preferredBufferSize: Int? = nil,
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
        return try await Subprocess.run(
            .path(FilePath(invocation.executable)),
            arguments: Arguments(invocation.arguments),
            environment: invocation.environment,
            workingDirectory: invocation.workingDirectory,
            preferredBufferSize: preferredBufferSize,
            isolation: isolation,
            body: body
        )
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
        let location = self.ssh ?? "local"
        if let workingDirectory = self.workingDirectory {
            return "\(location):\(workingDirectory)"
        }

        return "\(location):~"
    }
}
