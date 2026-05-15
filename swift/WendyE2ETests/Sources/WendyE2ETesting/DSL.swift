public import Subprocess

public struct WendyE2ESessionCommand: Sendable {
    public enum PollCondition: Sendable {
        case success
        case failure
    }

    public let session: WendyE2ESession
    public let command: String

    public func poll(
        until condition: PollCondition,
        step: Duration = .milliseconds(250),
        timeout: Duration = .seconds(10),
        timeoutMessage: String? = nil
    ) -> WendyE2ESessionCommand {
        precondition(step > .zero, "step must be greater than zero")
        precondition(timeout >= .zero, "timeout must be greater than or equal to zero")

        return WendyE2ESessionCommand(
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

    public func run() async throws {
        guard let pollConfiguration else {
            try await self.session.sh(self.command)
            return
        }

        _ = try await self.poll(
            pollConfiguration,
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
    }

    public func run<Result>(
        output: StringOutput<UTF8> = .string(limit: .max),
        error: StringOutput<UTF8> = .string(limit: .max),
        body: @Sendable (_ standardOutput: String, _ standardError: String) async throws -> Result
    ) async throws -> Result {
        guard let pollConfiguration else {
            return try await self.session.sh(
                self.command,
                output: output,
                error: error,
                body: body
            )
        }

        let record = try await self.poll(
            pollConfiguration,
            output: output,
            error: error
        )

        return try await body(
            record.standardOutput ?? "",
            record.standardError ?? ""
        )
    }

    // MARK: - Internal

    init(session: WendyE2ESession, command: String) {
        self.session = session
        self.command = command
        self.pollConfiguration = nil
    }

    // MARK: - Private

    private let pollConfiguration: PollConfiguration?

    private init(
        session: WendyE2ESession,
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
        error: StringOutput<UTF8>
    ) async throws -> ExecutionRecord<StringOutput<UTF8>, StringOutput<UTF8>> {
        let clock = ContinuousClock()
        let start = clock.now
        var lastTerminationStatus: TerminationStatus?

        while true {
            let record = try await self.session.sh(
                self.command,
                output: output,
                error: error
            )
            lastTerminationStatus = record.terminationStatus

            if configuration.condition.matches(record.terminationStatus) {
                return record
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < configuration.timeout else {
                throw WendyE2EMachineError.pollTimedOut(
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

extension WendyE2ESessionCommand.PollCondition: CustomStringConvertible {
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
    let condition: WendyE2ESessionCommand.PollCondition
    let step: Duration
    let timeout: Duration
    let timeoutMessage: String?
}

extension WendyE2ESessionCommand.PollCondition {
    fileprivate func matches(_ status: TerminationStatus) -> Bool {
        switch self {
        case .success:
            status.isSuccess
        case .failure:
            !status.isSuccess
        }
    }
}
