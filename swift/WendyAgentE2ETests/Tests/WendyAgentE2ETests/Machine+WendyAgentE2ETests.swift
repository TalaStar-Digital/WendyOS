import Foundation
import Testing
public import WendyE2ETesting

extension Machine {
    public static func cli() async throws -> Machine {
        let machine = Machine(
            name: "CLI",
            workingDirectory: Self.rootDirectoryURL().appendingPathComponent("go").path
        )

        try await buildCLIOnce.perform {
            try await machine.run("make build-cli") { standardOutput, _ in
                #expect(standardOutput.contains(/go build .* bin\/wendy/))
            }
        }

        return machine
    }

    public static func agent() async throws -> Machine {
        let machine = Machine(
            name: "Agent",
            workingDirectory: Self.rootDirectoryURL().appendingPathComponent("swift").path
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

    private static func rootDirectoryURL() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()  // Tests/WendyAgentE2ETests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift/WendyAgentE2ETests
            .deletingLastPathComponent()  // swift
            .deletingLastPathComponent()  // repository root
    }
}
