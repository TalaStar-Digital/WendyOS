import Foundation
import Testing

@Suite
struct `wendy cloud device dashboard` {
    // TODO: implement proper specs.
    // REFACTOR: Command-surface smoke specs intentionally duplicate this shape
    // until the full command coverage settles.

    @Test
    func `smoke help renders usage`() throws {
        let repositoryRootDirectoryURL = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()  // Tests/WendyE2ETests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift/WendyE2ETests
            .deletingLastPathComponent()  // swift
            .deletingLastPathComponent()  // repository root
        let goDirectoryURL = repositoryRootDirectoryURL.appendingPathComponent("go")
        let homeDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wendy-e2e-smoke-" + UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: homeDirectoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: homeDirectoryURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "wendy cloud device dashboard --help"]
        process.currentDirectoryURL = goDirectoryURL

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectoryURL.path
        environment["PATH"] = "\(goDirectoryURL.path)/bin:" + (environment["PATH"] ?? "")
        environment["WENDY_ANALYTICS"] = "false"
        process.environment = environment

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()
        process.waitUntilExit()

        let standardOutput =
            String(
                data: standardOutputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        let standardError =
            String(
                data: standardErrorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

        #expect(process.terminationStatus == 0)
        #expect(standardOutput.contains("Usage:"))
        #expect(standardOutput.contains("wendy cloud device dashboard"))
        #expect(standardError == "")
    }
}
