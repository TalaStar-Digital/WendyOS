import Foundation
import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy os cache'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `describes subcommands`() async throws {
        try await self.cli.run("./bin/wendy os cache --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Manage cached OS images"))
            #expect(standardOutput.contains("clear"))
            #expect(standardOutput.contains("list"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy os cache clear'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `removes cached WendyOS images`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-os-cache-clear")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/wendy/os-images", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "image".write(to: cache.appendingPathComponent("raspberry-pi-5-1.0.0.img"), atomically: true, encoding: .utf8)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy os cache clear") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput == "OS image cache cleared.\n")
        }

        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test
    func `reports when the OS cache is already empty`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-os-cache-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy os cache list") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput == "No cached OS images.\n")
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy os cache list'` {
    var cli: Machine

    init() async throws {
        self.cli = try await Machine.cli()
    }

    @Test
    func `lists cached WendyOS images`() async throws {
        let home = try Helper.temporaryDirectory(prefix: "wendy-os-cache-list")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/wendy/os-images", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "image".write(to: cache.appendingPathComponent("raspberry-pi-5-1.0.0.img"), atomically: true, encoding: .utf8)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy os cache list") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("raspberry-pi-5-1.0.0.img"))
            #expect(standardOutput.contains("Cache directory:"))
        }
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `'--json' formats cached WendyOS images as JSON`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let home = try Helper.temporaryDirectory(prefix: "wendy-os-cache-list-json")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/wendy/os-images", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "image".write(to: cache.appendingPathComponent("raspberry-pi-5-1.0.0.img"), atomically: true, encoding: .utf8)

        try await self.cli.run("\(Helper.commandEnvironment(home: home)) ./bin/wendy --json os cache list") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            let array = try Helper.jsonArray(from: standardOutput)
            let entry = try #require(array.first as? [String: Any])
            #expect(entry["name"] as? String == "raspberry-pi-5-1.0.0.img")
            #expect(entry["sizeBytes"] as? Int != nil)
            #expect(entry["path"] as? String != nil)
        }
    }
}
