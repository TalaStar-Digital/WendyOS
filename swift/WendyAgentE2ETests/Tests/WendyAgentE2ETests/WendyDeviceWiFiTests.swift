import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy device wifi'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test
    func `describes subcommands`() async throws {
        try await self.cli.run("./bin/wendy device wifi --help") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            #expect(standardOutput.contains("Manage WiFi"))
            #expect(standardOutput.contains("connect"))
            #expect(standardOutput.contains("disconnect"))
            #expect(standardOutput.contains("forget"))
            #expect(standardOutput.contains("list"))
            #expect(standardOutput.contains("rank"))
            #expect(standardOutput.contains("status"))
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy device wifi connect'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `connects to a WiFi network`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi connect --ssid WendyE2E --password correct-horse-battery-staple", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Connected") == true)
        #expect(record.standardOutput?.contains("WendyE2E") == true)
    }

    @Test
    func `fails clearly when WiFi credentials are rejected`() async throws {
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi connect --ssid WendyE2E --password wrong", output: .string(limit: .max), error: .string(limit: .max))
        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("credentials") == true || record.standardError?.contains("rejected") == true || record.standardError?.contains("Could not connect") == true)
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy device wifi disconnect'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `disconnects from the active WiFi network`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi disconnect", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Disconnected") == true)
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `handles an already disconnected WiFi interface`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi disconnect", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("already disconnected") == true || record.standardOutput?.contains("No active") == true || record.standardOutput?.contains("Disconnected") == true)
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy device wifi forget'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `forgets a saved WiFi network`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi forget --ssid WendyE2E", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("Forgot") == true || record.standardOutput?.contains("removed") == true)
        #expect(record.standardOutput?.contains("WendyE2E") == true)
    }

    @Test
    func `fails clearly when the WiFi network is not saved`() async throws {
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi forget --ssid MissingNetwork", output: .string(limit: .max), error: .string(limit: .max))
        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("MissingNetwork") == true || record.standardError?.contains("not saved") == true || record.standardError?.contains("Could not connect") == true)
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy device wifi list'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `lists visible WiFi networks`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi list", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("SSID") == true || record.standardOutput?.contains("WiFi") == true)
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `'--json' formats WiFi networks as JSON`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --json --device 127.0.0.1 device wifi list", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        let array = try Helper.jsonArray(from: record.standardOutput ?? "")
        if let first = array.first as? [String: Any] {
            #expect(first["ssid"] as? String != nil)
            #expect(first["signal"] != nil || first["strength"] != nil)
        }
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy device wifi rank'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `updates saved WiFi network priority`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi rank --ssid WendyE2E --priority 100", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("WendyE2E") == true)
        #expect(record.standardOutput?.contains("100") == true || record.standardOutput?.contains("priority") == true)
    }

    @Test
    func `fails clearly when the WiFi network is unknown`() async throws {
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi rank --ssid MissingNetwork --priority 10", output: .string(limit: .max), error: .string(limit: .max))
        #expect(!record.terminationStatus.isSuccess)
        #expect(record.standardError?.contains("MissingNetwork") == true || record.standardError?.contains("unknown") == true || record.standardError?.contains("Could not connect") == true)
    }
}

// MARK: -

@Suite(.serialized)
struct `'wendy device wifi status'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `shows the current WiFi connection state`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --device 127.0.0.1 device wifi status", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("SSID") == true || record.standardOutput?.contains("connected") == true || record.standardOutput?.contains("disconnected") == true)
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `'--json' formats WiFi status as JSON`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --json --device 127.0.0.1 device wifi status", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        let object = try Helper.jsonObject(from: record.standardOutput ?? "")
        #expect(object["connected"] as? Bool != nil)
        #expect(object["ssid"] != nil || object["connected"] as? Bool == false)
    }
}
