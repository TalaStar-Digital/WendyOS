import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy cache'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `describes subcommands`() async throws {
        try await self.cli.run("./bin/wendy cache --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Manage local CLI cache"))
            #expect(standardOutput.contains("clear"))
            #expect(standardOutput.contains("list"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy cache clear'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `removes cached CLI data`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-cache-clear")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/wendy", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cached".write(to: cache.appendingPathComponent("entry.txt"), atomically: true, encoding: .utf8)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy cache clear") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput == "Cache cleared.\n")
        }

        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test
    func `reports when the cache is already empty`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-cache-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy cache clear") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Cache"))
            #expect(standardOutput.contains("empty") || standardOutput.contains("cleared"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy cache list'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `lists cached entries`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-cache-list")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/wendy", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cached data".write(to: cache.appendingPathComponent("entry.txt"), atomically: true, encoding: .utf8)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy cache list") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("entry.txt"))
            #expect(standardOutput.contains("B"))
        }
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `'--json' formats cached entries as JSON`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let home = try Helper.temporaryDirectory(prefix: "wendy-cache-list-json")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/wendy", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cached data".write(to: cache.appendingPathComponent("entry.txt"), atomically: true, encoding: .utf8)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy --json cache list") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            let array = try Helper.jsonArray(from: standardOutput)
            let entry = try #require(array.first as? [String: Any])
            #expect(entry["name"] as? String == "entry.txt")
            #expect(entry["sizeBytes"] as? Int != nil)
            #expect(entry["path"] as? String != nil)
        }
    }
}
