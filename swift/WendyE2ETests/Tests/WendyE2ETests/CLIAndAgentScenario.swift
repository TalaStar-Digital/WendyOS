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
            let testName = URL(fileURLWithPath: recorder.testDirectoryPath, isDirectory: true)
                .lastPathComponent
            let fallbackTestDirectory = URL(
                fileURLWithPath: recorder.testDirectoryPath,
                isDirectory: true
            ).path
            let cliTestDirectory = Self.roleTestDirectoryPath(
                runDirectory: Environment.cliRunDirectory,
                fallbackDirectory: Self.path(fallbackTestDirectory, "cli"),
                testName: testName
            )
            let agentTestDirectory = Self.roleTestDirectoryPath(
                runDirectory: Environment.agentRunDirectory,
                fallbackDirectory: Self.path(fallbackTestDirectory, "agent"),
                testName: testName
            )
            let cliHomeDirectory = Self.path(cliTestDirectory, "home")
            let cliTemporaryDirectory = Self.path(cliTestDirectory, "tmp")
            let cliWorkingDirectory = Self.path(cliHomeDirectory, "work")
            let cliBinDirectory = Self.roleBinDirectory(
                runDirectory: Environment.cliRunDirectory,
                fallbackDirectory: repositoryRootDirectoryURL.appendingPathComponent("go/bin").path
            )
            let cliEnvironment = Self.roleEnvironment(
                homeDirectory: cliHomeDirectory,
                temporaryDirectory: cliTemporaryDirectory,
                binDirectory: cliBinDirectory
            )
            let agentHomeDirectory = Self.path(agentTestDirectory, "home")
            let agentTemporaryDirectory = Self.path(agentTestDirectory, "tmp")
            let agentWorkingDirectory = Self.path(agentHomeDirectory, "work")
            let agentBinDirectory = Self.roleBinDirectory(
                runDirectory: Environment.agentRunDirectory,
                fallbackDirectory: nil
            )
            let agentEnv = Self.roleEnvironment(
                homeDirectory: agentHomeDirectory,
                temporaryDirectory: agentTemporaryDirectory,
                binDirectory: agentBinDirectory
            )
            let cliSetupMachine = Machine(
                id: "cli-setup",
                name: "CLI setup",
                os: Environment.cliOS ?? .current,
                tags: [.cli],
                user: Environment.cliUser,
                address: Environment.cliAddress
            )
            let cliSetup = try await Session.begin(
                for: cliSetupMachine,
                workingDirectory: "/",
                env: cliEnvironment,
                recorder: recorder
            )
            cliSession = cliSetup
            try await cliSetup.sh("mkdir -p \"$HOME\" \"$TMPDIR\" \"$HOME/work\"")

            let agentSetupMachine = Machine(
                id: "agent-setup",
                name: "Agent setup",
                os: Environment.agentOS ?? .current,
                tags: [.agent],
                user: Environment.agentUser,
                address: Environment.agentAddress
            )
            let agentSetup = try await Session.begin(
                for: agentSetupMachine,
                workingDirectory: "/",
                env: agentEnv,
                recorder: recorder
            )
            agentSession = agentSetup
            try await agentSetup.sh("mkdir -p \"$HOME\" \"$TMPDIR\" \"$HOME/work\"")

            let cliMachine = Machine(
                id: "cli",
                name: "CLI",
                os: Environment.cliOS ?? .current,
                tags: [.cli],
                user: Environment.cliUser,
                address: Environment.cliAddress
            )

            let agentMachine = Machine(
                id: "agent",
                name: "Agent",
                os: Environment.agentOS ?? .current,
                tags: [.agent],
                user: Environment.agentUser,
                address: Environment.agentAddress
            )

            let cli = try await Session.begin(
                for: cliMachine,
                workingDirectory: cliWorkingDirectory,
                env: cliEnvironment,
                recorder: recorder
            )
            cliSession = cli
            let agent = try await Session.begin(
                for: agentMachine,
                workingDirectory: agentWorkingDirectory,
                env: agentEnv,
                recorder: recorder
            )
            agentSession = agent

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

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func roleTestDirectoryPath(
        runDirectory: String?,
        fallbackDirectory: String,
        testName: String
    ) -> String {
        guard let runDirectory else {
            return fallbackDirectory
        }

        return Self.path(runDirectory, "tests", testName)
    }

    private static func roleBinDirectory(
        runDirectory: String?,
        fallbackDirectory: String?
    ) -> String? {
        guard let runDirectory else {
            return fallbackDirectory
        }

        return Self.path(runDirectory, "bin")
    }

    private static func path(_ first: String, _ rest: String...) -> String {
        rest.reduce(first) { path, component in
            let suffix = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.hasSuffix("/") ? "\(path)\(suffix)" : "\(path)/\(suffix)"
        }
    }

    private static func roleEnvironment(
        homeDirectory: String,
        temporaryDirectory: String,
        binDirectory: String?
    ) -> [String: String] {
        var environment = [
            "HOME": homeDirectory,
            "TMPDIR": temporaryDirectory,
            "WENDY_ANALYTICS": "false",
        ]
        if let binDirectory {
            environment["PATH"] = "\(binDirectory):$PATH"
        }
        return environment
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
