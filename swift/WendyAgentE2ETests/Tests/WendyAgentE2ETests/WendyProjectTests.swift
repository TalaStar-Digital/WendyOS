import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy project'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test
    func `describes configuration subcommands`() async throws {
        try await self.cli.sh("./bin/wendy project --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Manage Wendy project configuration"))
            #expect(standardOutput.contains("entitlements"))
        }
    }

    @Test(
        .disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation.")
    )
    func `fails clearly outside a configured workspace`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-project-no-workspace")
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements list",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("wendy.json") == true)
        #expect(
            record.standardError?.contains("not found") == true
                || record.standardError?.contains("No") == true
        )
    }
}
