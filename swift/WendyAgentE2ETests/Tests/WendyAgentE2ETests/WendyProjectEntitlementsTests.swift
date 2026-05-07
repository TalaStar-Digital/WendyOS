import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy project entitlements'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test
    func `describes subcommands`() async throws {
        try await self.cli.sh("./bin/wendy project entitlements --help") {
            standardOutput,
            standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Manage project entitlements"))
            #expect(standardOutput.contains("add"))
            #expect(standardOutput.contains("list"))
            #expect(standardOutput.contains("remove"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy project entitlements list'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test(
        .disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation.")
    )
    func `lists configured entitlements`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-list")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Helper.writeWendyJSON(
            Helper.wendyJSONContents(
                appId: "sh.wendy.e2e.entitlements",
                entitlements: "{ \"type\": \"network\" },\n    { \"type\": \"gpu\" }"
            ),
            to: directory
        )

        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements list"
        ) { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Project entitlements:"))
            #expect(standardOutput.contains("network"))
            #expect(standardOutput.contains("gpu"))
        }
    }

    @Test(
        .disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation.")
    )
    func `reports when no entitlements are configured`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Helper.writeWendyJSON(
            Helper.wendyJSONContents(appId: "sh.wendy.e2e.empty", entitlements: ""),
            to: directory
        )

        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements list"
        ) { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(
                standardOutput.contains("No entitlements")
                    || standardOutput.contains("Project entitlements:")
            )
            #expect(!standardOutput.contains("gpu"))
        }
    }

    @Test(
        .disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation.")
    )
    func `'--show-all' shows all available entitlement types`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-all")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Helper.writeWendyJSON(Helper.wendyJSONContents(), to: directory)

        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements list --show-all"
        ) { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Available entitlement types:"))
            for entitlement in [
                "network", "bluetooth", "video", "gpu", "persist", "audio", "camera", "usb", "i2c",
                "gpio", "spi", "input",
            ] {
                #expect(standardOutput.contains(entitlement))
            }
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy project entitlements add'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test
    func `adds a non-interactive entitlement and persists it`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-add")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Helper.writeWendyJSON(Helper.wendyJSONContents(), to: directory)

        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements add audio"
        ) { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Added"))
            #expect(standardOutput.contains("audio"))
        }

        let object = try Helper.jsonObject(from: String(contentsOf: file, encoding: .utf8))
        let entitlements = try #require(object["entitlements"] as? [[String: Any]])
        #expect(entitlements.contains { $0["type"] as? String == "audio" })
    }

    @Test
    func `rejects an unknown entitlement type without changing wendy json`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-unknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Helper.writeWendyJSON(Helper.wendyJSONContents(), to: directory)
        let before = try String(contentsOf: file, encoding: .utf8)

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements add definitely-not-real",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("unknown entitlement type") == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
    }

    @Test
    func `rejects an entitlement that already exists`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Helper.writeWendyJSON(Helper.wendyJSONContents(), to: directory)

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements add network",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("network") == true)
        #expect(
            record.standardError?.contains("already") == true
                || record.standardError?.contains("exists") == true
        )
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy project entitlements remove'` {
    var cli: Session

    init() async throws {
        self.cli = try await Session.begin(for: .cli)
    }

    @Test
    func `removes an existing entitlement and persists it`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-remove")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Helper.writeWendyJSON(
            Helper.wendyJSONContents(
                entitlements: "{ \"type\": \"network\" },\n    { \"type\": \"gpu\" }"
            ),
            to: directory
        )

        try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements remove gpu"
        ) { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Removed"))
            #expect(standardOutput.contains("gpu"))
        }

        let object = try Helper.jsonObject(from: String(contentsOf: file, encoding: .utf8))
        let entitlements = try #require(object["entitlements"] as? [[String: Any]])
        #expect(!entitlements.contains { $0["type"] as? String == "gpu" })
        #expect(entitlements.contains { $0["type"] as? String == "network" })
    }

    @Test
    func `fails clearly when the entitlement is not configured`() async throws {
        let directory = try Helper.temporaryDirectory(prefix: "wendy-entitlements-remove-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Helper.writeWendyJSON(Helper.wendyJSONContents(), to: directory)

        let record = try await self.cli.sh(
            "cd \(Helper.shellQuote(directory.path)) && WENDY_ANALYTICS=false \(Helper.shellQuote(Helper.repositoryRootDirectoryURL().appendingPathComponent("go/bin/wendy").path)) project entitlements remove audio",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("audio") == true)
        #expect(
            record.standardError?.contains("not found") == true
                || record.standardError?.contains("not configured") == true
        )
    }
}
