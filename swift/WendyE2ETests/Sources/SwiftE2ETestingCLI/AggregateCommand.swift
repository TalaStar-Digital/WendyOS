import ArgumentParser
import Foundation

struct AggregateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aggregate",
        abstract: "Aggregate Swift E2E attempts into a run layout."
    )

    @Option(
        name: .long,
        help: "Directory where the E2E run is written. Defaults to the first attempt's parent."
    )
    var outputDir: String?

    @Argument(help: "Swift E2E attempt directories to aggregate.")
    var attemptDirs: [String] = []

    mutating func run() throws {
        guard !attemptDirs.isEmpty else {
            throw ValidationError("Missing attempt directory.")
        }

        let attemptURLs = attemptDirs.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let firstAttemptURL = attemptURLs[0]
        let outputURL = URL(
            fileURLWithPath: outputDir ?? firstAttemptURL.deletingLastPathComponent().path,
            isDirectory: true
        ).standardizedFileURL

        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        var runURLs: Set<URL> = []
        for attemptURL in attemptURLs {
            let attemptID = attemptURL.lastPathComponent
            let components = try AttemptID(attemptID)
            let runURL = outputURL.appendingPathComponent(
                "\(components.workflowName).\(components.runID)",
                isDirectory: true
            )
            runURLs.insert(runURL)
            try FileManager.default.createDirectory(
                at: runURL,
                withIntermediateDirectories: true
            )

            try mapAttempt(
                attemptURL: attemptURL,
                components: components,
                runURL: runURL
            )
        }

        for root in runURLs.sorted(by: { $0.path < $1.path }) {
            print("==> Wrote Swift E2E run: \(root.path)")
        }
    }

    private func mapAttempt(
        attemptURL: URL,
        components: AttemptID,
        runURL: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: attemptURL.path) else {
            throw ValidationError("Attempt directory does not exist: \(attemptURL.path)")
        }

        let testsURL = attemptURL.appendingPathComponent("tests", isDirectory: true)
        let testDirectories = try attemptTestDirectories(in: testsURL)
        for testDirectory in testDirectories {
            let suiteKey = testDirectory.deletingLastPathComponent().lastPathComponent
            let testKey = testDirectory.lastPathComponent
            let destinationURL =
                runURL
                .appendingPathComponent(suiteKey, isDirectory: true)
                .appendingPathComponent(testKey, isDirectory: true)
                .appendingPathComponent(components.targetName, isDirectory: true)
                .appendingPathComponent(components.attempt, isDirectory: true)

            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try copyItem(at: testDirectory, to: destinationURL)
            try copyAttemptLevelFiles(from: attemptURL, to: destinationURL)
        }
    }
}

private struct AttemptID {
    var workflowName: String
    var runID: String
    var targetName: String
    var attempt: String

    init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else {
            throw ValidationError(
                "Attempt ID must have shape <workflow-name>.<run-id>.<target-name>.<attempt>: \(value)"
            )
        }
        self.workflowName = parts[0]
        self.runID = parts[1]
        self.targetName = parts.dropFirst(2).dropLast().joined(separator: ".")
        self.attempt = parts[parts.count - 1]
        guard !workflowName.isEmpty, !runID.isEmpty, !targetName.isEmpty, !attempt.isEmpty else {
            throw ValidationError("Attempt ID contains an empty component: \(value)")
        }
    }
}

private func attemptTestDirectories(in testsURL: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: testsURL.path) else {
        return []
    }
    guard
        let enumerator = FileManager.default.enumerator(
            at: testsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
    else {
        throw ValidationError("Tests directory cannot be read: \(testsURL.path)")
    }

    var directories: [URL] = []
    for case let url as URL in enumerator {
        let recordURL = url.appendingPathComponent("recording.md")
        if FileManager.default.fileExists(atPath: recordURL.path) {
            directories.append(url)
        }
    }
    return directories.sorted { $0.path < $1.path }
}

private func copyAttemptLevelFiles(from attemptURL: URL, to destinationURL: URL) throws {
    for fileName in ["attempt.json", "test-results.xml", "test-results.raw.xml"] {
        let sourceURL = attemptURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
        try copyItem(at: sourceURL, to: destinationURL.appendingPathComponent(fileName))
    }
}

private func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
}

