import Foundation
import WendyE2ETesting

final class CLIAndAgentScenario: Scenario, Sendable {
    // MARK: - Internal

    func run<Result>(
        filePath: String = #filePath,
        function: String = #function,
        line: Int = #line,
        _ body: @Sendable (_ cli: Session, _ agent: Session) async throws -> Result
    ) async throws -> Result {
        let (cli, agent) = try await self.setUp(
            filePath: filePath,
            function: function,
            line: line
        )

        let result: Result
        do {
            result = try await body(cli, agent)
        } catch {
            try? await Self.tearDown(
                cli: cli,
                agent: agent
            )
            throw error
        }

        try await Self.tearDown(
            cli: cli,
            agent: agent
        )
        return result
    }

    // MARK: - Private

    private func setUp(
        filePath: String,
        function: String,
        line: Int
    ) async throws -> (cli: Session, agent: Session) {
        var cliSession: Session?
        var agentSession: Session?

        do {
            let recorder = try Recorder(
                filePath: filePath,
                function: function,
                line: line
            )
            let repositoryRootDirectoryURL = Self.repositoryRootDirectoryURL()
            let cliWorkingDirectory =
                Environment.cliWorkingDirectory
                ?? repositoryRootDirectoryURL.appendingPathComponent("go").path
            let cliHomeDirectory = "/tmp/wendy-e2e-cli-home-\(UUID().uuidString)"

            let cliMachine = Machine(
                id: "cli",
                name: "CLI",
                os: Environment.cliOS ?? .current,
                tags: [.cli],
                user: Environment.cliUser,
                address: Environment.cliAddress,
                workingDirectory: cliWorkingDirectory,
                env: [
                    "HOME": cliHomeDirectory,
                    "PATH": "\(cliWorkingDirectory)/bin:$PATH",
                    "WENDY_ANALYTICS": "false",
                ]
            )

            let agentMachine = Machine(
                id: "agent",
                name: "Agent",
                os: Environment.agentOS ?? .current,
                tags: [.agent],
                user: Environment.agentUser,
                address: Environment.agentAddress,
                workingDirectory: Environment.agentWorkingDirectory
                    ?? repositoryRootDirectoryURL.appendingPathComponent("swift").path
            )

            let cli = try await Session.begin(
                for: cliMachine,
                recorder: recorder
            )
            cliSession = cli
            let agent = try await Session.begin(
                for: agentMachine,
                recorder: recorder
            )
            agentSession = agent

            try await cli.sh("mkdir -p \"$HOME\"")

            return (cli, agent)
        } catch {
            try? await Self.tearDown(
                cli: cliSession,
                agent: agentSession
            )
            throw error
        }
    }

    private static func tearDown(
        cli: Session?,
        agent: Session?
    ) async throws {
        var firstError: (any Error)?

        if let cli {
            do {
                try await cli.sh(
                    """
                    if [ -d "$HOME" ]; then
                      chmod -R u+w "$HOME" 2>/dev/null || true
                      rm -rf "$HOME"
                    fi
                    """
                )
            } catch {
                firstError = firstError ?? error
            }
        }
        if let agent {
            do {
                try await agent.end()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let cli {
            do {
                try await cli.end()
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private static func repositoryRootDirectoryURL() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()  // Tests/WendyE2ETests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift/WendyE2ETests
            .deletingLastPathComponent()  // swift
            .deletingLastPathComponent()  // repository root
    }
}
