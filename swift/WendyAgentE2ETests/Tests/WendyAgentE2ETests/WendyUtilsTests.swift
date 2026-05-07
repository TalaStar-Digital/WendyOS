import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy utils'` {
    var cli: Session
    init() async throws { self.cli = try await Session.begin(for: .cli) }

    @Test
    func `describes utility subcommands`() async throws {
        try await self.cli.sh("./bin/wendy utils --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Utility commands"))
            #expect(standardOutput.contains("open-browser"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy utils open-browser'` {
    var cli: Session
    init() async throws { self.cli = try await Session.begin(for: .cli) }

    @Test
    func `opens the requested URL in the system browser`() async throws {
        let record = try await self.cli.sh(
            "WENDY_ANALYTICS=false ./bin/wendy utils open-browser http://127.0.0.1:9",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
        #expect(record.terminationStatus.isSuccess)
        #expect(
            record.standardOutput?.contains("Opened") == true
                || record.standardOutput?.contains("http://127.0.0.1:9") == true
        )
        #expect(record.standardError?.isEmpty == true)
    }

    @Test
    func `fails clearly when the URL is invalid`() async throws {
        let record = try await self.cli.sh(
            "WENDY_ANALYTICS=false ./bin/wendy utils open-browser not-a-url",
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
        #expect(!record.terminationStatus.isSuccess)
        #expect(
            record.standardError?.contains("invalid") == true
                || record.standardError?.contains("URL") == true
        )
    }
}
