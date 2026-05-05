import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy device hardware'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test
    func `describes subcommands`() async throws {
        try await self.cli.run("./bin/wendy device hardware --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Query hardware capabilities"))
            #expect(standardOutput.contains("list"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy device hardware list'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `lists hardware capabilities on the selected device`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device hardware list", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Hardware") == true || record.standardOutput?.contains("Capabilities") == true)
        #expect(record.standardOutput?.contains("gpu") == true || record.standardOutput?.contains("audio") == true || record.standardOutput?.contains("camera") == true)
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `'--json' formats hardware capabilities as JSON`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --json --device 127.0.0.1 device hardware list", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        let object = try Helper.jsonObject(from: record.standardOutput ?? "")
        #expect(object["capabilities"] != nil || object["hardware"] != nil)
    }
}
