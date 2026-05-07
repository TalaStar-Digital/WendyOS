import Subprocess

public struct SessionCommand: Sendable {
    public enum PollCondition: Sendable {
        case success
        case failure
    }

    public let session: Session
    public let command: String

    public func poll(
        until condition: PollCondition,
        step: Duration = .milliseconds(250),
        timeout: Duration = .seconds(10),
        timeoutMessage: String? = nil
    ) -> SessionCommand {
        precondition(step > .zero, "step must be greater than zero")
        precondition(timeout >= .zero, "timeout must be greater than or equal to zero")

        return SessionCommand(
            session: self.session,
            command: self.command,
            pollConfiguration: PollConfiguration(
                condition: condition,
                step: step,
                timeout: timeout,
                timeoutMessage: timeoutMessage
            )
        )
    }

    public func run(
        filePath: String = #filePath,
        function: String = #function,
        line: Int = #line
    ) async throws {
        guard let pollConfiguration else {
            try await self.session.sh(
                self.command,
                filePath: filePath,
                function: function,
                line: line
            )
            return
        }

        _ = try await self.poll(
            pollConfiguration,
            output: .string(limit: .max),
            error: .string(limit: .max),
            filePath: filePath,
            function: function,
            line: line
        )
    }

    public func run<Result>(
        output: StringOutput<UTF8> = .string(limit: .max),
        error: StringOutput<UTF8> = .string(limit: .max),
        filePath: String = #filePath,
        function: String = #function,
        line: Int = #line,
        body: @Sendable (_ standardOutput: String, _ standardError: String) async throws -> Result
    ) async throws -> Result {
        guard let pollConfiguration else {
            return try await self.session.sh(
                self.command,
                output: output,
                error: error,
                filePath: filePath,
                function: function,
                line: line,
                body: body
            )
        }

        let record = try await self.poll(
            pollConfiguration,
            output: output,
            error: error,
            filePath: filePath,
            function: function,
            line: line
        )

        return try await body(
            record.standardOutput ?? "",
            record.standardError ?? ""
        )
    }

    // MARK: - Internal

    init(session: Session, command: String) {
        self.session = session
        self.command = command
        self.pollConfiguration = nil
    }

    // MARK: - Private

    private let pollConfiguration: PollConfiguration?

    private init(
        session: Session,
        command: String,
        pollConfiguration: PollConfiguration?
    ) {
        self.session = session
        self.command = command
        self.pollConfiguration = pollConfiguration
    }

    private func poll(
        _ configuration: PollConfiguration,
        output: StringOutput<UTF8>,
        error: StringOutput<UTF8>,
        filePath: String,
        function: String,
        line: Int
    ) async throws -> ExecutionRecord<StringOutput<UTF8>, StringOutput<UTF8>> {
        let clock = ContinuousClock()
        let start = clock.now
        var lastTerminationStatus: TerminationStatus?

        while true {
            let record = try await self.session.sh(
                self.command,
                output: output,
                error: error,
                filePath: filePath,
                function: function,
                line: line
            )
            lastTerminationStatus = record.terminationStatus

            if configuration.condition.matches(record.terminationStatus) {
                return record
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < configuration.timeout else {
                throw MachineError.pollTimedOut(
                    machine: self.session.description,
                    command: self.command,
                    condition: configuration.condition.description,
                    timeout: configuration.timeout,
                    lastTerminationStatus: lastTerminationStatus,
                    message: configuration.timeoutMessage
                )
            }

            try await clock.sleep(for: min(configuration.step, configuration.timeout - elapsed))
        }
    }
}

// MARK: - CustomStringConvertible

extension SessionCommand.PollCondition: CustomStringConvertible {
    public var description: String {
        switch self {
        case .success:
            return "success"
        case .failure:
            return "failure"
        }
    }
}

// MARK: - Private

private struct PollConfiguration: Sendable {
    let condition: SessionCommand.PollCondition
    let step: Duration
    let timeout: Duration
    let timeoutMessage: String?
}

extension SessionCommand.PollCondition {
    fileprivate func matches(_ terminationStatus: TerminationStatus) -> Bool {
        switch self {
        case .success:
            return terminationStatus.isSuccess
        case .failure:
            return !terminationStatus.isSuccess
        }
    }
}
