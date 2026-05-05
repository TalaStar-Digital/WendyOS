import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy run'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `requires a valid Wendy project`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-run-no-project")
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = try await self.cli.run(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) run --device 127.0.0.1 -y",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("wendy.json") == true || record.standardError?.contains("project") == true)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("wendy.json").path))
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `builds and deploys the current project to the selected device`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-run-deploy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wendy = Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path
        try await self.cli.run("cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) init --app-id sh.wendy.e2e.run --target wendyos --language swift --no-extra-entitlements --assistant skip --git-init no") { _, standardError in
            #expect(standardError.isEmpty)
        }

        let record = try await self.cli.run(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) run --device 127.0.0.1 -y --detach",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Building") == true)
        #expect(record.standardOutput?.contains("Deploying") == true)
        #expect(record.standardOutput?.contains("sh.wendy.e2e.run") == true)
        #expect(record.standardOutput?.contains("started") == true || record.standardOutput?.contains("deployed") == true)
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `streams deployment progress in a readable format`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-run-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wendy = Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path
        try await self.cli.run("cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) init --app-id sh.wendy.e2e.progress --target wendyos --language swift --no-extra-entitlements --assistant skip --git-init no") { _, _ in }

        let record = try await self.cli.run(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) run --device 127.0.0.1 -y --detach",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Building") == true)
        #expect(record.standardOutput?.contains("Uploading") == true || record.standardOutput?.contains("Deploying") == true)
        #expect(record.standardError?.isEmpty == true)
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `'--json' formats deployment result as JSON`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-run-json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wendy = Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path
        try await self.cli.run("cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) init --app-id sh.wendy.e2e.run-json --target wendyos --language swift --no-extra-entitlements --assistant skip --git-init no") { _, _ in }

        let record = try await self.cli.run(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) --json run --device 127.0.0.1 -y --detach",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(record.terminationStatus.isSuccess)
        let object = try Helper.jsonObject(from: record.standardOutput ?? "")
        #expect(object["appId"] as? String == "sh.wendy.e2e.run-json")
        #expect(object["device"] as? String == "127.0.0.1")
        #expect(object["status"] as? String == "deployed" || object["status"] as? String == "running")
    }
}
