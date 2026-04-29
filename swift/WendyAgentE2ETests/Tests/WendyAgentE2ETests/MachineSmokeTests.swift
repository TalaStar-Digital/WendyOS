import Foundation
import Testing

@testable import WendyAgentE2E

extension Tag {
    @Tag static var e2e: Self
}

@Suite("Machine smoke tests", .serialized, .tags(.e2e))
struct MachineSmokeTests {
    @Test("build over a persistent SSH machine session", .timeLimit(.minutes(10)))
    func buildOverPersistentSSHMachineSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WENDY_E2E_SMOKE"] == "1" else {
            return
        }

        let machineSpec = try #require(environment["E2E_MACHINE"])
        let machine = try Machine.parse(machineSpec)
        defer {
            Task {
                try? await machine.close()
            }
        }

        try await machine.run("cd swift && make build-dev")
        try await machine.run("cd go && make build")
    }
}
