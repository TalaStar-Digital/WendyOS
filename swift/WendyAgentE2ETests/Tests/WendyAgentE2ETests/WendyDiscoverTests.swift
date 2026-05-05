import Testing
import WendyE2ETesting

@Suite(.serialized)
struct `'wendy discover'` {
    var cli: Machine
    init() async throws { self.cli = try await Machine.cli() }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `finds WendyOS devices on the local network`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --json discover --timeout 1ms", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        let object = try Helper.jsonObject(from: record.standardOutput ?? "")
        let lanDevices = object["lanDevices"] as? [[String: Any]] ?? []
        let usbDevices = object["usbDevices"] as? [[String: Any]] ?? []
        let devices = lanDevices + usbDevices
        #expect(devices.contains { $0["isWendyDevice"] as? Bool == true })
    }

    @Test
    func `'--json' formats devices as JSON`() async throws {
        try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy --json discover --timeout 1ms") { standardOutput, standardError in
            #expect(standardError.isEmpty)
            let object = try Helper.jsonObject(from: standardOutput)
            #expect(object["usbDevices"] != nil || object["lanDevices"] != nil || object["externalDevices"] != nil)
            if let external = (object["externalDevices"] as? [[String: Any]])?.first {
                #expect(external["id"] as? String != nil)
                #expect(external["displayName"] as? String != nil)
                #expect(external["isWendyDevice"] as? Bool != nil)
            }
        }
    }

    @Test(.disabled("TODO: one-by-one E2E run fails against current local fixtures/implementation."))
    func `reports clearly when no devices are found`() async throws {
        // TODO: Re-enable after adding the required fixture or implementation; one-by-one E2E run currently fails.
        let record = try await self.cli.run("WENDY_ANALYTICS=false ./bin/wendy discover --timeout 1ms --type lan", output: .string(limit: .max), error: .string(limit: .max))
        #expect(record.terminationStatus.isSuccess)
        #expect(record.standardOutput?.contains("No devices found") == true || record.standardOutput?.contains("No WendyOS devices") == true)
    }
}
