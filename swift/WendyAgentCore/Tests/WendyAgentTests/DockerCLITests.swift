import Foundation
import Testing

@testable import WendyAgentCore

struct DockerCLITests {
    @Test("checkAvailable returns false when the docker probe times out")
    func checkAvailableReturnsFalseWhenProbeTimesOut() async throws {
        let scriptURL = try Self.makeExecutableScript(
            name: "fake-docker-timeout.sh",
            contents: """
                #!/bin/sh
                sleep 1
                exit 0
                """
        )
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let docker = DockerCLI(
            executable: scriptURL.path,
            startupCommandTimeout: .milliseconds(100)
        )

        let available = await docker.checkAvailable()

        #expect(available == false)
    }

    @Test("checkAvailable returns true when the docker probe completes")
    func checkAvailableReturnsTrueWhenProbeCompletes() async throws {
        let scriptURL = try Self.makeExecutableScript(
            name: "fake-docker-ok.sh",
            contents: """
                #!/bin/sh
                echo 27.0.1
                exit 0
                """
        )
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let docker = DockerCLI(
            executable: scriptURL.path,
            startupCommandTimeout: .seconds(2)
        )

        let available = await docker.checkAvailable()

        #expect(available == true)
    }

    private static func makeExecutableScript(name: String, contents: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let scriptURL = directoryURL.appendingPathComponent(name)
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }
}
