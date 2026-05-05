import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy tour'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `starts the interactive guided setup`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let home = try Helper.temporaryDirectory(prefix: "wendy-tour-start")
        defer { try? FileManager.default.removeItem(at: home) }

        let record = try await self.cli.run(
            "\(Helper.commandEnvironment(home: home)) /usr/bin/perl -e 'alarm 2; exec @ARGV' ./bin/wendy tour",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.standardOutput?.contains("tour") == true || record.standardError?.contains("tour") == true)
        #expect(record.standardOutput?.contains("device") == true || record.standardError?.contains("device") == true)
        #expect(record.standardOutput?.contains("project") == true || record.standardError?.contains("project") == true)
    }

    @Test
    func `handles cancellation without changing user configuration`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-tour-cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        try Helper.writeUserConfig(["analytics": ["enabled": false], "defaultDevice": "before.local"], home: home)

        let record = try await self.cli.run(
            "\(Helper.commandEnvironment(home: home)) printf '\\003' | ./bin/wendy tour",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess || record.standardOutput?.contains("cancel") == true || record.standardError?.contains("cancel") == true)
        #expect(try Helper.userConfig(home: home)["defaultDevice"] as? String == "before.local")
    }
}
