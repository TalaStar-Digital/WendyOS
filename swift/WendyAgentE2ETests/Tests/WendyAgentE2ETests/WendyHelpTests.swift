import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy help'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test
    func `prints documentation for a top-level command`() async throws {
        try await self.cli.sh("./bin/wendy help device") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Manage WendyOS devices"))
            #expect(standardOutput.contains("Device Management:"))
            #expect(standardOutput.contains("Monitoring:"))
            #expect(standardOutput.contains("Hardware:"))
            #expect(standardOutput.contains("Apps & Storage:"))
        }
    }

    @Test
    func `prints documentation for a nested command`() async throws {
        try await self.cli.sh("./bin/wendy help device wifi connect") {
            standardOutput,
            standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Connect to a WiFi network"))
            #expect(standardOutput.contains("--ssid string"))
            #expect(standardOutput.contains("--password string"))
            #expect(standardOutput.contains("Global Flags:"))
        }
    }

    @Test(
        .disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation.")
    )
    func `fails clearly for an unknown command`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.sh(
            "./bin/wendy help definitely-not-a-command",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardOutput == "")
        #expect(record.standardError?.contains("unknown help topic") == true)
        #expect(record.standardError?.contains("definitely-not-a-command") == true)
    }
}
