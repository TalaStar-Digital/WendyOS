import Foundation
import Testing

@testable import SwiftE2ETestingCLI

@Suite
struct `run overview` {
    @Test
    func `keeps noteworthy evidence without duplicating suite content`() throws {
        let rootURL = e2eTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runURL = rootURL.appendingPathComponent("Run", isDirectory: true)
        let suiteURL = runURL.appendingPathComponent(
            "wendy-device-info",
            isDirectory: true
        )
        let testURL = suiteURL.appendingPathComponent(
            "prints-json-device-information",
            isDirectory: true
        )
        let targetURL = testURL.appendingPathComponent("macos-to-rpi", isDirectory: true)
        let attemptOneURL = targetURL.appendingPathComponent("0001", isDirectory: true)
        let attemptTwoURL = targetURL.appendingPathComponent("0002", isDirectory: true)

        try FileManager.default.createDirectory(
            at: attemptOneURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attemptTwoURL,
            withIntermediateDirectories: true
        )

        try writeXUnitResult(
            to: attemptOneURL,
            status: .failed("device did not respond"),
            duration: 1.25
        )
        try writeXUnitResult(to: attemptTwoURL, status: .passed, duration: 0.75)
        try "# Recording\n\n## Command 1\n".write(
            to: attemptOneURL.appendingPathComponent("recording.md"),
            atomically: true,
            encoding: .utf8
        )

        let overview = try writeRunOverview(in: runURL)
        let overviewData = try Data(contentsOf: runOverviewURL(in: runURL))
        let overviewJSON = String(data: overviewData, encoding: .utf8) ?? ""

        #expect(overview.schema == "wendy.e2e.overview.v1")
        #expect(!overviewJSON.contains("\"suites\""))
        #expect(overview.summary.tests == 1)
        #expect(overview.summary.testTargets == 1)
        #expect(overview.summary.attemptResults == 2)
        #expect(overview.summary.commands == 1)
        #expect(overview.summary.flaked == 1)
        #expect(overview.noteworthy.flakes.count == 1)

        let flake = overview.noteworthy.flakes[0]
        #expect(flake.suite == "wendy-device-info")
        #expect(flake.test == "prints-json-device-information")
        #expect(flake.target == "macos-to-rpi")
        #expect(flake.attempts.map { $0.status } == [.failed, .passed])
        #expect(flake.attempts.first?.durationSeconds == 1.25)
    }

}

private func e2eTemporaryDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("wendy-e2e-cli-tests-\(UUID().uuidString)", isDirectory: true)
}

private enum XUnitStatus {
    case passed
    case failed(String)
}

private func writeXUnitResult(
    to attemptURL: URL,
    status: XUnitStatus,
    duration: Double
) throws {
    let result: String
    switch status {
    case .passed:
        result = xUnitTestCase(duration: duration, body: nil)
    case .failed(let message):
        result = xUnitTestCase(duration: duration, body: "<failure message=\"\(message)\" />")
    }

    let xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<testsuite tests=\"1\">\(result)</testsuite>"
    try xml.write(
        to: attemptURL.appendingPathComponent("test-results.xml"),
        atomically: true,
        encoding: .utf8
    )
}

private func xUnitTestCase(duration: Double, body: String?) -> String {
    let attributes =
        "classname=\"WendyE2ETests.`wendy device info`\" "
        + "name=\"prints JSON device information()\" "
        + "time=\"\(duration)\""
    guard let body else {
        return "<testcase \(attributes) />"
    }
    return "<testcase \(attributes)>\(body)</testcase>"
}
