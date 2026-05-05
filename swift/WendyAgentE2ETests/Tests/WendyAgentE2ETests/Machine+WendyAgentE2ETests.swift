import Foundation
import Testing
public import WendyE2ETesting

extension Machine {
    public static func cli(ssh: String? = nil, verbose: Bool = false) async throws -> Machine {
        let machine = Machine(
            name: "CLI",
            ssh: ssh ?? envValue("WENDY_AGENT_E2E_CLI_SSH"),
            workingDirectory: envValue("WENDY_AGENT_E2E_CLI_WORKING_DIRECTORY")
                ?? Helper.repositoryRootDirectoryURL().appendingPathComponent("go").path,
            verbose: verbose || envFlag("WENDY_AGENT_E2E_VERBOSE")
        )

        try await buildCLIOnce.perform {
            try await machine.run("make build-cli") { standardOutput, _ in
                #expect(standardOutput.contains(/go build .* bin\/wendy/))
            }
        }

        return machine
    }

    public static func agent(ssh: String? = nil, verbose: Bool = false) async throws -> Machine {
        let machine = Machine(
            name: "Agent",
            ssh: ssh ?? envValue("WENDY_AGENT_E2E_AGENT_SSH"),
            workingDirectory: envValue("WENDY_AGENT_E2E_AGENT_WORKING_DIRECTORY")
                ?? Helper.repositoryRootDirectoryURL().appendingPathComponent("swift")
                .path,
            verbose: verbose || envFlag("WENDY_AGENT_E2E_VERBOSE")
        )

        try await buildAgentOnce.perform {
            try await machine.run("make build-dev") { standardOutput, _ in
                #expect(
                    standardOutput.contains(
                        /Created macOS app artifact: .*wendy-agent-macos-arm64-.*\.zip/
                    )
                )
            }
        }

        return machine
    }

    // MARK: - Private

    private static let buildCLIOnce = Once(name: "build CLI")
    private static let buildAgentOnce = Once(name: "build agent")

    private static func envValue(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func envFlag(_ name: String) -> Bool {
        guard let value = envValue(name)?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }
}
