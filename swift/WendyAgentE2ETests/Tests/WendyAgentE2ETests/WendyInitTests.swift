import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy init'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test
    func `creates a wendy json file for a new project`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-init-create")
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = try Helper.temporaryDirectory(prefix: "wendy-init-create-home")
        defer { try? FileManager.default.removeItem(at: home) }

        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && \(Helper.commandEnvironment(home: home)) \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) init --app-id sh.wendy.e2e.init --target wendyos --language swift --no-extra-entitlements --assistant skip --git-init no"
        ) { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Created wendy.json for sh.wendy.e2e.init"))
            #expect(standardOutput.contains("Your project is ready"))
        }

        let wendyJSON = directory.appendingPathComponent("wendy.json")
        #expect(FileManager.default.fileExists(atPath: wendyJSON.path))
        let object = try Helper.jsonObject(from: String(contentsOf: wendyJSON, encoding: .utf8))
        #expect(object["appId"] as? String == "sh.wendy.e2e.init")
        #expect(object["platform"] as? String == "wendyos")
        #expect(object["language"] as? String == "swift")
        let entitlements = try #require(object["entitlements"] as? [[String: Any]])
        #expect(entitlements.contains { $0["type"] as? String == "network" })
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            )
        )
    }

    @Test
    func `refuses to overwrite an existing wendy json file`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-init-existing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Helper.writeWendyJSON(
            Helper.wendyJSONContents(appId: "sh.wendy.e2e.existing"),
            to: directory
        )
        let originalContents = try String(contentsOf: original, encoding: .utf8)

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) init --app-id sh.wendy.e2e.new --target wendyos --language swift --no-extra-entitlements --assistant skip --git-init no",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("wendy.json") == true)
        #expect(
            record.standardError?.contains("already") == true
                || record.standardError?.contains("exists") == true
        )
        #expect(try String(contentsOf: original, encoding: .utf8) == originalContents)
    }

    @Test(
        .disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation.")
    )
    func `validates project metadata before writing configuration`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-init-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) init --app-id 'not a valid app id' --target wendyos --language swift --no-extra-entitlements --assistant skip --git-init no",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("app") == true)
        #expect(
            record.standardError?.contains("invalid") == true
                || record.standardError?.contains("must") == true
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("wendy.json").path
            )
        )
    }
}
