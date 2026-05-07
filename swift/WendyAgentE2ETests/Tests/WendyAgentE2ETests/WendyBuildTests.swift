import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy build'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test(
        .disabled(
            "TODO: hangs when run interactively because wendy build prompts to create wendy.json."
        )
    )
    func `requires a valid Wendy project`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-build-no-project")
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) build",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(
            record.standardError?.contains("project") == true
                || record.standardError?.contains("wendy.json") == true
        )
        #expect(
            record.standardError?.contains("supported build type") == true
                || record.standardError?.contains("valid") == true
        )
    }

    @Test
    func `produces the current project artifact`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-build-project")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wendy = Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path
        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) init --app-id sh.wendy.e2e.build --target wendyos --language swift --no-extra-entitlements --assistant skip --git-init no"
        ) { _, standardError in
            #expect(standardError.isEmpty)
        }

        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(wendy)) build"
        ) { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Building Swift project"))
            #expect(standardOutput.contains("Build completed successfully"))
        }

        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".build/debug/sh.wendy.e2e.build").path
            )
        )
    }

    @Test
    func `reports wendy json validation errors`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-build-invalid-json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Helper.writeWendyJSON(
            """
            {
              "version": "1.0.0",
              "platform": "wendyos",
              "language": "swift"
            }
            """,
            to: directory
        )
        try Helper.writeFile(
            """
            // swift-tools-version:6.2
            import PackageDescription
            let package = Package(name: "Invalid", targets: [.executableTarget(name: "Invalid")])
            """,
            named: "Package.swift",
            to: directory
        )

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) build",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("appId") == true)
        #expect(
            record.standardError?.contains("wendy.json") == true
                || record.standardError?.contains("validation") == true
        )
    }
}
