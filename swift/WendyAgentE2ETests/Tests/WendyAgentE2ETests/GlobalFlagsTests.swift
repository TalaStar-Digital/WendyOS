import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `global flags` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `'--json' formats supported command output as JSON`() async throws {
        try await self.cli.run("./bin/wendy --json info") { standardOutput, standardError in
            #expect(standardError.isEmpty)

            let object = try Helper.jsonObject(from: standardOutput)

            #expect(object["version"] as? String == "dev")
            #expect(object["os"] as? String == "darwin")
            #expect(object["arch"] as? String == "arm64")
            #expect((object["goVersion"] as? String)?.hasPrefix("go") == true)
            #expect(!standardOutput.contains("Wendy CLI"))
        }

        // AI:
        // - The --json flag switches supported commands from human text to JSON.
        // - JSON keys are stable and useful for automation.
        // - No human-oriented headings, warnings, or noisy diagnostics are printed.
    }

    @Test
    func `'--device' overrides the selected target device`() async throws {
        let agent = try await Machine.agent()

        try await agent.run("make quit || true")
        try await Helper.withAsyncCleanup {
            try await agent.run("open Build/WendyAgentMac.app")
            try await agent
                .command("nc -z 127.0.0.1 50051")
                .poll(
                    until: .success,
                    step: .milliseconds(250),
                    timeout: .seconds(10),
                    timeoutMessage: "WendyAgentMac did not open port 50051"
                )
                .run()

            try await self.cli.run("./bin/wendy --json --device 127.0.0.1 device version") {
                standardOutput,
                standardError in
                #expect(standardError.isEmpty)

                let object = try Helper.jsonObject(from: standardOutput)

                #expect(object["os"] as? String == "darwin")
                #expect((object["version"] as? String)?.isEmpty == false)
                #expect((object["cliVersion"] as? String)?.isEmpty == false)
                #expect((object["cpuArchitecture"] as? String)?.isEmpty == false)
            }
        } cleanup: {
            try await agent.run("make quit || true")
        }

        // AI:
        // - The CLI reaches the explicitly selected agent via --device.
        // - The response describes the agent machine, not just local CLI state.
        // - JSON output stays stable enough for automation.
    }
}
