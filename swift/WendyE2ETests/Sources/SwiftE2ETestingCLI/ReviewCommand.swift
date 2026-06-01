import ArgumentParser
import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

struct ReviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Review a Swift E2E run with Pi."
    )

    @Option(name: .long, help: "Swift package directory.")
    var packageDir = "."

    @Option(name: .long, help: "Directory containing Swift E2E test sources.")
    var testsDir: String?

    @Option(
        name: .long,
        help: "E2E run directory. Reads run results and writes AI review files."
    )
    var runDir: String

    @Option(name: .long, help: "Pi model name. Passed through as WENDY_E2E_PI_MODEL.")
    var model: String?

    @Option(name: .long, help: "Suite review prompt path.")
    var suiteReviewPrompt: String?

    @Option(name: .long, help: "Run report review prompt path.")
    var reportReviewPrompt: String?

    @Option(name: .long, help: "Run review stage: suites, report, or all.")
    var stage: RunReviewStage = .all

    @Option(
        name: .long,
        help: "Git diff range for diff-scoped review, for example origin/main...HEAD."
    )
    var diff: String?

    @Flag(name: .long, help: "Overwrite existing review files.")
    var overwrite = false

    mutating func run() async throws {
        let packageURL = URL(fileURLWithPath: packageDir).standardizedFileURL
        let testsURL = URL(
            fileURLWithPath: testsDir ?? defaultReviewTestsDir(packageURL: packageURL).path
        ).standardizedFileURL
        let runURL = URL(fileURLWithPath: runDir, isDirectory: true).standardizedFileURL
        let repoURL = packageURL.deletingLastPathComponent().deletingLastPathComponent()
            .standardizedFileURL

        guard try isReviewRunDirectory(runURL) else {
            throw ValidationError(
                "Swift E2E review expects a Swift E2E run directory. Run E2EAggregate first, then pass the run directory to --run-dir."
            )
        }

        try await runReview(
            packageURL: packageURL,
            testsURL: testsURL,
            runURL: runURL,
            repoURL: repoURL
        )
    }
}

extension ReviewCommand {
    fileprivate func runReview(
        packageURL: URL,
        testsURL: URL,
        runURL: URL,
        repoURL: URL
    ) async throws {
        let reviewMode = try ReviewMode(diff: diff)
        let context = try reviewMode.prepareContext(runURL: runURL, repoURL: repoURL)
        let suitePromptURL = URL(
            fileURLWithPath: suiteReviewPrompt
                ?? packageURL.appendingPathComponent("Support/\(reviewMode.suitePromptFileName)")
                .path
        ).standardizedFileURL
        let reportPromptURL = URL(
            fileURLWithPath: reportReviewPrompt
                ?? packageURL.appendingPathComponent("Support/\(reviewMode.reportPromptFileName)")
                .path
        ).standardizedFileURL
        let suitePrompt = try String(contentsOf: suitePromptURL, encoding: .utf8)
        let reportPrompt = try String(contentsOf: reportPromptURL, encoding: .utf8)
        let piHarness = try makePiHarness(model: model)
        let resolvedModel = piHarness.modelName
        let reviewer = e2eReviewReviewer(model: resolvedModel)
        let reviewDirectoryName = e2eReviewDirectoryName(reviewer: reviewer)
        let suites = try loadRunReviewSuites(
            testsURL: testsURL,
            runURL: runURL,
            reviewer: reviewer
        )
        print("==> Running Swift E2E run AI review")
        print("    Harness:        pi")
        print("    Command source: \(piHarness.commandSource)")
        print("    Invocation:     \(piHarness.invocationSummary)")
        print("    Model:          \(resolvedModel)")
        print("    Model source:   \(piHarness.modelSource)")
        print("    Auth:           \(piHarness.authSummary)")
        print("    Repo:           \(repoURL.path)")
        print("    Run:            \(runURL.path)")
        print("    Mode:           \(reviewMode.name)")
        print("    Reviewer:       \(reviewer)")
        print("    Review dir:     \(reviewDirectoryName)")
        if let range = reviewMode.diffRange {
            print("    Diff:           \(range)")
        }
        if let changedFilesURL = context.changedFilesURL {
            print("    Name-only diff: \(changedFilesURL.path)")
        }
        if let diffstatURL = context.diffstatURL {
            print("    Diff stat:      \(diffstatURL.path)")
        }
        print("    Suites:         \(suites.count)")
        print("    Suite prompt:   \(suitePromptURL.path)")
        print("    Report prompt:  \(reportPromptURL.path)")

        if overwrite {
            try removeExistingRunReviews(in: runURL, reviewer: reviewer)
        }

        if stage == .suites || stage == .all {
            print("==> Running suite-scoped run AI reviews")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for suite in suites {
                    group.addTask {
                        let reviewHarness = try makePiHarness(model: resolvedModel)
                        let prompt = runSuitePrompt(
                            basePrompt: suitePrompt,
                            suite: suite,
                            repoURL: repoURL,
                            packageURL: packageURL,
                            testsURL: testsURL,
                            runURL: runURL,
                            context: context,
                            reviewer: reviewer,
                            reviewDirectoryName: reviewDirectoryName,
                            overwrite: overwrite
                        )
                        print("Progress: reviewing suite \(suite.suiteKey)")
                        try reviewHarness.review(
                            prompt: prompt,
                            repoURL: repoURL,
                            runURL: runURL
                        )
                    }
                }
                try await group.waitForAll()
            }
            let suiteFiles = try enforceRunSuiteReviewContract(in: runURL, reviewer: reviewer)
            print("==> Suite-scoped run AI reviews complete")
            print("    Review files: \(suiteFiles)")
        }

        if stage == .report || stage == .all {
            print("==> Running run report AI review")
            let prompt = try runReportPrompt(
                basePrompt: reportPrompt,
                suites: suites,
                repoURL: repoURL,
                packageURL: packageURL,
                testsURL: testsURL,
                runURL: runURL,
                context: context,
                reviewer: reviewer,
                reviewDirectoryName: reviewDirectoryName,
                overwrite: overwrite
            )
            let reportHarness = try makePiHarness(model: resolvedModel)
            try reportHarness.review(
                prompt: prompt,
                repoURL: repoURL,
                runURL: runURL
            )
            try enforceRunReportReviewContract(in: runURL, reviewer: reviewer)
            print("==> Run report AI review complete")
        }

    }
}

private enum ReviewMode {
    case full
    case diff(String)

    init(diff: String?) throws {
        guard let diff else {
            self = .full
            return
        }
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError("--diff must not be empty.")
        }
        self = .diff(trimmed)
    }

    var name: String {
        switch self {
        case .full:
            "full"
        case .diff:
            "diff"
        }
    }

    var diffRange: String? {
        if case .diff(let range) = self { range } else { nil }
    }

    var suitePromptFileName: String {
        "e2e-review-suite.\(name).prompt.md"
    }

    var reportPromptFileName: String {
        "e2e-review-report.\(name).prompt.md"
    }

    func prepareContext(runURL: URL, repoURL: URL) throws -> ReviewContext {
        switch self {
        case .full:
            return ReviewContext(mode: self, changedFilesURL: nil, diffstatURL: nil)
        case .diff(let range):
            let changedFilesURL = runURL.appendingPathComponent("git-diff-name-only.txt")
            let diffstatURL = runURL.appendingPathComponent("git-diff-stat.txt")

            try runGitDiffContext(
                arguments: ["diff", "--name-only", range],
                outputURL: changedFilesURL,
                repoURL: repoURL,
                diffRange: range
            )
            try runGitDiffContext(
                arguments: ["diff", "--stat", range],
                outputURL: diffstatURL,
                repoURL: repoURL,
                diffRange: range
            )
            return ReviewContext(
                mode: self,
                changedFilesURL: changedFilesURL,
                diffstatURL: diffstatURL
            )
        }
    }
}

private struct ReviewContext {
    var mode: ReviewMode
    var changedFilesURL: URL?
    var diffstatURL: URL?
}

enum RunReviewStage: String, ExpressibleByArgument {
    case suites
    case report
    case all

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

private struct ReviewTestCase {
    var sourcePath: String
    var suite: String
    var name: String
    var funcLine: Int
    var sourceBody: String
    var aiComments: [String]
}

private enum ReviewTestStatus {
    case passed
    case failed(String?)
    case skipped(String?)
    case unknown

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .passed:
            "passed"
        case .failed:
            "failed"
        case .skipped:
            "skipped"
        case .unknown:
            "unknown"
        }
    }

    var detail: String? {
        switch self {
        case .failed(let detail), .skipped(let detail):
            detail
        case .passed, .unknown:
            nil
        }
    }
}

private struct ReviewTestObservation {
    var status: ReviewTestStatus
    var durationSeconds: Double?
}

private struct RunReviewObservation {
    var target: String
    var attempt: String
    var status: ReviewTestStatus
    var durationSeconds: Double?
    var recordingPath: String?
    var shellPath: String?

    var isFailed: Bool { status.isFailed }
}

private struct RunReviewTest {
    var test: ReviewTestCase
    var suiteKey: String
    var testKey: String
    var observations: [RunReviewObservation]
    var existingReviews: [E2EReview]
}

private struct RunReviewSuite {
    var suiteKey: String
    var displayName: String
    var sourceURL: URL
    var tests: [RunReviewTest]
    var existingReviews: [E2EReview]
}

private struct ReviewResultKey: Hashable {
    var suite: String
    var name: String
}

private struct ShellReviewHarness {
    var modelName: String
    var shellCommand: String
    var commandSource: String
    var invocationSummary: String
    var authSummary: String
    var modelSource: String
    var modelEnvironmentKey: String?

    func review(prompt: String, repoURL: URL, runURL: URL) throws {
        let promptURL = runURL.appendingPathComponent(
            ".review-harness-prompt-\(UUID().uuidString).md"
        )
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: promptURL) }

        var environment = ProcessInfo.processInfo.environment
        environment["WENDY_E2E_REVIEW_PROMPT"] = promptURL.path
        environment["WENDY_E2E_REVIEW_RUN_DIR"] = runURL.path
        environment["WENDY_E2E_REVIEW_REPO_DIR"] = repoURL.path
        if let modelEnvironmentKey {
            if usesHarnessDefaultModel(modelName) {
                environment.removeValue(forKey: modelEnvironmentKey)
            } else {
                environment[modelEnvironmentKey] = modelName
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", shellCommand]
        process.currentDirectoryURL = repoURL
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError(
                "Pi review failed with exit status \(process.terminationStatus)."
            )
        }
    }
}

private func makePiHarness(model: String?) throws -> ShellReviewHarness {
    let environment = ProcessInfo.processInfo.environment
    let customCommand = environment["WENDY_E2E_PI_COMMAND", default: ""]
    let usesCustomCommand = !customCommand.isEmpty
    if !usesCustomCommand {
        try requireExecutable("pi", harness: "pi")
    }
    let auth = try piAuth(
        environment: environment,
        usesCustomCommand: usesCustomCommand
    )
    let modelSelection = piModelSelection(
        explicitModel: model,
        environment: environment,
        auth: auth,
        usesCustomCommand: usesCustomCommand
    )
    return ShellReviewHarness(
        modelName: modelSelection.name,
        shellCommand: usesCustomCommand
            ? customCommand
            : #"prompt="Read and follow the E2E review instructions in $WENDY_E2E_REVIEW_PROMPT."; pi --model "$WENDY_E2E_PI_MODEL" -p "$prompt""#,
        commandSource: usesCustomCommand ? "WENDY_E2E_PI_COMMAND" : "pi CLI",
        invocationSummary: piInvocationSummary(
            modelName: modelSelection.name,
            usesCustomCommand: usesCustomCommand
        ),
        authSummary: auth.summary,
        modelSource: modelSelection.source,
        modelEnvironmentKey: "WENDY_E2E_PI_MODEL"
    )
}

private func piInvocationSummary(modelName: String, usesCustomCommand: Bool) -> String {
    if usesCustomCommand {
        return "custom shell command (not printed; may contain secrets)"
    }
    return "pi --model \(modelName) -p <generated prompt>"
}

private struct PiAuth {
    var openAICodexOAuth: Bool
    var anthropicOAuth: Bool
    var openAIAPIKey: Bool
    var anthropicAPIKey: Bool
    var summary: String
}

private struct PiModelSelection {
    var name: String
    var source: String
}

private func piAuth(environment: [String: String], usesCustomCommand: Bool) throws -> PiAuth {
    if usesCustomCommand {
        return PiAuth(
            openAICodexOAuth: false,
            anthropicOAuth: false,
            openAIAPIKey: false,
            anthropicAPIKey: false,
            summary: "custom command; auth handled by WENDY_E2E_PI_COMMAND"
        )
    }

    let authPath =
        environment["PI_CODING_AGENT_DIR"].map { "\($0)/auth.json" }
        ?? "\(NSHomeDirectory())/.pi/agent/auth.json"
    let subscriptions = piAuthTypes(at: authPath)
    let auth = PiAuth(
        openAICodexOAuth: subscriptions.openAICodexOAuth,
        anthropicOAuth: subscriptions.anthropicOAuth,
        openAIAPIKey: !environment["OPENAI_API_KEY", default: ""].isEmpty,
        anthropicAPIKey: !environment["ANTHROPIC_API_KEY", default: ""].isEmpty,
        summary: piAuthSummary(
            openAICodexOAuth: subscriptions.openAICodexOAuth,
            anthropicOAuth: subscriptions.anthropicOAuth,
            openAIAPIKey: !environment["OPENAI_API_KEY", default: ""].isEmpty,
            anthropicAPIKey: !environment["ANTHROPIC_API_KEY", default: ""].isEmpty
        )
    )

    if auth.summary.isEmpty {
        throw ValidationError(
            "Pi review requires recognized auth. Configure OpenAI Codex or Anthropic subscription auth in \(authPath), set OPENAI_API_KEY or ANTHROPIC_API_KEY, or set WENDY_E2E_PI_COMMAND."
        )
    }
    return auth
}

private func piAuthSummary(
    openAICodexOAuth: Bool,
    anthropicOAuth: Bool,
    openAIAPIKey: Bool,
    anthropicAPIKey: Bool
) -> String {
    var parts: [String] = []
    if openAICodexOAuth {
        parts.append("OpenAI Codex subscription")
    }
    if anthropicOAuth {
        parts.append("Anthropic subscription")
    }
    if openAIAPIKey {
        parts.append("OPENAI_API_KEY")
    }
    if anthropicAPIKey {
        parts.append("ANTHROPIC_API_KEY")
    }
    return parts.joined(separator: ", ")
}

private func piModelSelection(
    explicitModel: String?,
    environment: [String: String],
    auth: PiAuth,
    usesCustomCommand: Bool
) -> PiModelSelection {
    if let explicitModel, !usesHarnessDefaultModel(explicitModel) {
        return PiModelSelection(name: explicitModel, source: "--model")
    }
    let environmentModel = environment["WENDY_E2E_PI_MODEL", default: ""]
    if !usesHarnessDefaultModel(environmentModel) {
        return PiModelSelection(name: environmentModel, source: "WENDY_E2E_PI_MODEL")
    }
    if usesCustomCommand {
        return PiModelSelection(name: "default", source: "WENDY_E2E_PI_COMMAND")
    }
    if auth.openAICodexOAuth {
        return PiModelSelection(name: "openai-codex/gpt:high", source: "OpenAI Codex subscription")
    }
    if auth.anthropicOAuth {
        return PiModelSelection(
            name: "anthropic/claude-opus:high",
            source: "Anthropic subscription"
        )
    }
    if auth.openAIAPIKey {
        return PiModelSelection(name: "openai/gpt:high", source: "OPENAI_API_KEY")
    }
    if auth.anthropicAPIKey {
        return PiModelSelection(name: "anthropic/claude-opus:high", source: "ANTHROPIC_API_KEY")
    }
    return PiModelSelection(name: "default", source: "unresolved")
}

private func piAuthTypes(at path: String) -> (openAICodexOAuth: Bool, anthropicOAuth: Bool) {
    guard let data = FileManager.default.contents(atPath: path),
        let object = try? JSONSerialization.jsonObject(with: data),
        let auth = object as? [String: Any]
    else {
        return (false, false)
    }

    func hasOAuthProvider(_ key: String) -> Bool {
        guard let provider = auth[key] as? [String: Any],
            let type = provider["type"] as? String
        else {
            return false
        }
        return type == "oauth"
    }

    return (
        openAICodexOAuth: hasOAuthProvider("openai-codex"),
        anthropicOAuth: hasOAuthProvider("anthropic")
    )
}

private func usesHarnessDefaultModel(_ modelName: String) -> Bool {
    let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty || normalized == "default" || normalized == "latest"
}

private func requireExecutable(_ name: String, harness: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", name]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ValidationError("\(harness) requires `\(name)` to be installed on PATH.")
    }
}

private func isReviewRunDirectory(_ runURL: URL) throws -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: runURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        return false
    }
    return !FileManager.default.fileExists(
        atPath: runURL.appendingPathComponent("attempt.json").path
    )
}

private func runGitDiffContext(
    arguments: [String],
    outputURL: URL,
    repoURL: URL,
    diffRange: String
) throws {
    try Data().write(to: outputURL, options: .atomic)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }

    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = repoURL
    process.standardOutput = output
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        try? FileManager.default.removeItem(at: outputURL)
        throw error
    }
    process.waitUntilExit()

    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errorData, as: UTF8.self)

    guard process.terminationStatus == 0 else {
        try? FileManager.default.removeItem(at: outputURL)
        let command = (["git"] + arguments).joined(separator: " ")
        var message =
            "Could not resolve Git diff range `\(diffRange)` while generating Swift E2E review context."
        message += " Ensure the repository has enough history and the range is fetchable."
        message += " Command `\(command)` failed with exit status \(process.terminationStatus)."
        let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            message += "\n\(detail)"
        }
        throw ValidationError(message)
    }
}

private func loadRunReviewSuites(
    testsURL: URL,
    runURL: URL,
    reviewer: String
) throws -> [RunReviewSuite] {
    let tests = try parseReviewTests(in: testsURL)
    let testsByPathKey = Dictionary(grouping: tests) { test in
        let sourceURL = URL(fileURLWithPath: test.sourcePath)
        return RunReviewPathKey(
            suiteKey: reviewRecordFileStem(sourceURL),
            testKey: reviewSlug(test.name)
        )
    }

    var suites: [RunReviewSuite] = []
    for suiteURL in try runReviewDirectoryChildren(of: runURL) {
        let suiteKey = suiteURL.lastPathComponent
        guard !isE2EReviewDirectoryName(suiteKey) else { continue }
        var suiteTests: [RunReviewTest] = []
        var sourceURL: URL?
        var displayName = suiteKey

        for testURL in try runReviewDirectoryChildren(of: suiteURL) {
            let testKey = testURL.lastPathComponent
            guard
                let test = testsByPathKey[
                    RunReviewPathKey(suiteKey: suiteKey, testKey: testKey)
                ]?.first
            else {
                continue
            }
            let testSourceURL = URL(fileURLWithPath: test.sourcePath)
            sourceURL = sourceURL ?? testSourceURL
            displayName = test.suite
            suiteTests.append(
                RunReviewTest(
                    test: test,
                    suiteKey: suiteKey,
                    testKey: testKey,
                    observations: try runReviewObservations(
                        suiteKey: suiteKey,
                        testKey: testKey,
                        testURL: testURL,
                        runURL: runURL
                    ),
                    existingReviews: try loadE2EReviews(
                        in: testURL,
                        expectedScope: "test",
                        expectedReviewer: reviewer,
                        relativeTo: runURL
                    )
                )
            )
        }

        if !suiteTests.isEmpty, let sourceURL {
            suites.append(
                RunReviewSuite(
                    suiteKey: suiteKey,
                    displayName: displayName,
                    sourceURL: sourceURL,
                    tests: suiteTests.sorted { $0.test.funcLine < $1.test.funcLine },
                    existingReviews: try loadE2EReviews(
                        in: suiteURL,
                        expectedScope: "suite",
                        expectedReviewer: reviewer,
                        relativeTo: runURL
                    )
                )
            )
        }
    }
    return suites.sorted { $0.suiteKey < $1.suiteKey }
}

private struct RunReviewPathKey: Hashable {
    var suiteKey: String
    var testKey: String
}

private func runReviewObservations(
    suiteKey: String,
    testKey: String,
    testURL: URL,
    runURL: URL
) throws -> [RunReviewObservation] {
    var observations: [RunReviewObservation] = []
    for targetURL in try runReviewDirectoryChildren(of: testURL) {
        let targetName = targetURL.lastPathComponent
        for attemptURL in try runReviewDirectoryChildren(of: targetURL) {
            let attemptName = attemptURL.lastPathComponent
            let result = try runReviewObservationResult(
                suiteKey: suiteKey,
                testKey: testKey,
                attemptURL: attemptURL
            )
            observations.append(
                RunReviewObservation(
                    target: targetName,
                    attempt: attemptName,
                    status: result.status,
                    durationSeconds: result.durationSeconds,
                    recordingPath: runReviewRelativeFilePath(
                        fileName: "recording.md",
                        attemptURL: attemptURL,
                        runURL: runURL
                    ),
                    shellPath: runReviewRelativeFilePath(
                        fileName: "recording.sh.txt",
                        attemptURL: attemptURL,
                        runURL: runURL
                    )
                )
            )
        }
    }
    return observations.sorted {
        if $0.target != $1.target { return $0.target < $1.target }
        return $0.attempt < $1.attempt
    }
}

private func runReviewObservationResult(
    suiteKey: String,
    testKey: String,
    attemptURL: URL
) throws -> ReviewTestObservation {
    let resultURL = attemptURL.appendingPathComponent("test-results.xml")
    guard FileManager.default.fileExists(atPath: resultURL.path) else {
        return ReviewTestObservation(status: .unknown, durationSeconds: nil)
    }
    let data = try Data(contentsOf: resultURL)
    let parser = ReviewXUnitResultParser()
    let xmlParser = XMLParser(data: data)
    xmlParser.delegate = parser
    guard xmlParser.parse() else {
        throw ValidationError("Could not parse Swift Testing xUnit results: \(resultURL.path)")
    }
    return parser.results.first { key, _ in
        reviewSlug(key.suite) == suiteKey && reviewSlug(key.name) == testKey
    }?.value ?? ReviewTestObservation(status: .unknown, durationSeconds: nil)
}

private func runReviewDirectoryChildren(of url: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .sorted { $0.path < $1.path }
}

private func runReviewRelativeFilePath(
    fileName: String,
    attemptURL: URL,
    runURL: URL
) -> String? {
    let url = attemptURL.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return reviewRelativePath(url, base: runURL)
}

private func runSuitePrompt(
    basePrompt: String,
    suite: RunReviewSuite,
    repoURL: URL,
    packageURL: URL,
    testsURL: URL,
    runURL: URL,
    context: ReviewContext,
    reviewer: String,
    reviewDirectoryName: String,
    overwrite: Bool
) -> String {
    var lines = runPromptHeader(
        title: "Suite-scoped Swift E2E run review",
        basePrompt: basePrompt,
        repoURL: repoURL,
        packageURL: packageURL,
        testsURL: testsURL,
        runURL: runURL,
        context: context
    )
    lines.append("## Suite")
    lines.append("")
    lines.append("- Suite key: `\(suite.suiteKey)`")
    lines.append("- Suite name: `\(suite.displayName)`")
    lines.append("- Source: `\(suite.sourceURL.path)`")
    lines.append(
        "- Suite review directory: `\(runURL.appendingPathComponent(suite.suiteKey).appendingPathComponent(reviewDirectoryName).path)`"
    )
    lines.append(
        "- Test review directories: `<run>/\(suite.suiteKey)/<test-key>/\(reviewDirectoryName)/`"
    )
    appendReviewOutputContract(
        to: &lines,
        writableScopes: "suite and test",
        reviewer: reviewer,
        reviewDirectoryName: reviewDirectoryName,
        overwrite: overwrite
    )
    lines.append("")
    lines.append("## Tests in this suite")
    lines.append("")
    for test in suite.tests {
        appendRunReviewTest(test, to: &lines, runURL: runURL)
    }
    return lines.joined(separator: "\n")
}

private func runReportPrompt(
    basePrompt: String,
    suites: [RunReviewSuite],
    repoURL: URL,
    packageURL: URL,
    testsURL: URL,
    runURL: URL,
    context: ReviewContext,
    reviewer: String,
    reviewDirectoryName: String,
    overwrite: Bool
) throws -> String {
    var lines = runPromptHeader(
        title: "Top-level Swift E2E run review",
        basePrompt: basePrompt,
        repoURL: repoURL,
        packageURL: packageURL,
        testsURL: testsURL,
        runURL: runURL,
        context: context
    )
    lines.append("## Report scope")
    lines.append("")
    lines.append(
        "- Report review directory: `\(runURL.appendingPathComponent(reviewDirectoryName).path)`"
    )
    appendReviewOutputContract(
        to: &lines,
        writableScopes: "report",
        reviewer: reviewer,
        reviewDirectoryName: reviewDirectoryName,
        overwrite: overwrite
    )
    lines.append(
        "For report-level reviews, only create findings that are run-level or cross-suite. Do not repeat suite/test reviews already covered at lower scopes."
    )
    lines.append("")
    lines.append("## Run summary")
    lines.append("")
    for suite in suites {
        lines.append("### \(suite.displayName) (`\(suite.suiteKey)`)")
        appendExistingReviews(suite.existingReviews, label: "Suite reviews", to: &lines)
        for test in suite.tests {
            let failures = test.observations.filter(\.isFailed).count
            let flaked = runReviewTargetOutcomeCounts(test.observations).flaked
            lines.append(
                "- `\(test.test.name)` (`\(test.suiteKey)/\(test.testKey)`): attempt-results=\(test.observations.count), failed=\(failures), flaked-targets=\(flaked)"
            )
            appendExistingReviews(
                test.existingReviews,
                label: "Test reviews",
                to: &lines,
                prefix: "  "
            )
        }
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

private func runPromptHeader(
    title: String,
    basePrompt: String,
    repoURL: URL,
    packageURL: URL,
    testsURL: URL,
    runURL: URL,
    context: ReviewContext
) -> [String] {
    var lines = [
        "# \(title)",
        "",
        basePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
        "",
        "## Context",
        "",
        "- Repository root: `\(repoURL.path)`",
        "- Swift package: `\(packageURL.path)`",
        "- Swift E2E tests: `\(testsURL.path)`",
        "- Run directory: `\(runURL.path)`",
        "",
        "Walk only the canonical run depth. Do not recursively scan copied `cli/` or `agent/` sandboxes unless you intentionally inspect a specific artifact referenced below.",
        "Print short `Progress:` lines while reviewing so CI shows activity.",
        "",
    ]

    appendReviewContext(context, to: &lines)
    return lines
}

private func appendReviewOutputContract(
    to lines: inout [String],
    writableScopes: String,
    reviewer: String,
    reviewDirectoryName: String,
    overwrite: Bool
) {
    lines.append("")
    lines.append("## Output contract")
    lines.append("")
    lines.append(
        "Write one Markdown file per actionable review issue under the appropriate `\(reviewDirectoryName)/` directory. Writable scopes for this prompt: \(writableScopes)."
    )
    lines.append(
        "The file name must be the review title slug with `.md`: lowercase ASCII letters/digits, non-alphanumerics replaced by `-`, repeated dashes collapsed, and leading/trailing dashes removed. Example: `seed-cache-fixtures-before-listing.md`."
    )
    lines.append(
        "Use JSON `severity` to classify each issue as `info`, `concern`, or `fail`. Do not write prose status/severity lines such as `Status: pass`, `Status: concern`, or `Status: fail`."
    )
    lines.append(
        "If nothing is noteworthy at a scope, leave that `\(reviewDirectoryName)/` directory absent or empty."
    )
    if !overwrite {
        lines.append(
            "If existing review files are still valid and accurate, leave them in place; otherwise rewrite or remove stale files."
        )
    }
    lines.append("")
    lines.append("Each review file must have this exact shape:")
    lines.append("")
    lines.append("```md")
    lines.append("---")
    lines.append("{")
    lines.append("  \"schema\": \"\(e2eReviewSchemaID)\",")
    lines.append("  \"title\": \"Seed cache fixtures before listing values\",")
    lines.append("  \"scope\": \"test\",")
    lines.append("  \"reviewer\": \"\(reviewer)\",")
    lines.append("  \"severity\": \"concern\",")
    lines.append("  \"confidence\": \"medium\",")
    lines.append("  \"locations\": [")
    lines.append(
        "    { \"path\": \"swift/WendyE2ETests/Tests/WendyE2ETests/WendyCacheListTests.swift\", \"startLine\": 42, \"endLine\": 48 }"
    )
    lines.append("  ],")
    lines.append("  \"evidence\": [")
    lines.append(
        "    { \"path\": \"wendy-cache-list/prints-values/ubuntu-24-04/0001/recording.md\" }"
    )
    lines.append("  ]")
    lines.append("}")
    lines.append("---")
    lines.append("")
    lines.append("# Seed cache fixtures before listing values")
    lines.append("")
    lines.append("Short GitHub-comment-sized summary of the finding and suggested action.")
    lines.append("")
    lines.append("## Details")
    lines.append("")
    lines.append("Full analysis, evidence, and suggested follow-up.")
    lines.append("```")
    lines.append("")
    lines.append(
        "The JSON `title` must match the Markdown `# Title`; the file name must be the slugged title; `scope` must be `report`, `suite`, or `test` matching the directory where the file is written; `reviewer` must be `\(reviewer)`."
    )
    lines.append(
        "Use `locations` only when the review is attributable to code lines in the repository. Use repo-relative paths and one-based line numbers. Use `evidence` for run-relative artifact paths."
    )
}

private func appendExistingReviews(
    _ reviews: [E2EReview],
    label: String,
    to lines: inout [String],
    prefix: String = ""
) {
    guard !reviews.isEmpty else {
        if prefix.isEmpty {
            lines.append("\(prefix)- \(label): `<none>`")
        }
        return
    }

    lines.append("\(prefix)- \(label):")
    for review in reviews {
        lines.append("\(prefix)  - `\(review.path)`: \(review.title)")
        lines.append("\(prefix)    ```md")
        lines.append(indent(review.summaryMarkdown, prefix: "\(prefix)    "))
        lines.append("\(prefix)    ```")
    }
}

private func appendReviewContext(_ context: ReviewContext, to lines: inout [String]) {
    lines.append("## Review mode")
    lines.append("")
    lines.append("- Mode: `\(context.mode.name)`")

    guard case .diff(let range) = context.mode else {
        lines.append("")
        return
    }

    lines.append("- Git diff range: `\(range)`")
    if let changedFilesURL = context.changedFilesURL {
        lines.append("- Changed files: `\(changedFilesURL.path)`")
    }
    if let diffstatURL = context.diffstatURL {
        lines.append("- Diffstat: `\(diffstatURL.path)`")
    }
    lines.append("")
    lines.append(
        "Only report findings plausibly related to the supplied Git diff range. Treat unrelated pre-existing failures, flakes, or test quality issues as background unless the diff appears to introduce or worsen them."
    )
    lines.append(
        "Do not look for a saved full patch; inspect targeted diffs on demand with commands like:"
    )
    lines.append("")
    lines.append("```bash")
    lines.append("git diff --stat \(range)")
    lines.append("git diff --name-only \(range)")
    lines.append("git diff \(range) -- <specific-file>")
    lines.append("git diff \(range) -U80 -- <specific-file>")
    lines.append("```")
    lines.append("")
}

private func appendRunReviewTest(
    _ test: RunReviewTest,
    to lines: inout [String],
    runURL: URL
) {
    lines.append("### \(test.test.suite) › \(test.test.name)")
    lines.append("- Test key: `\(test.suiteKey)/\(test.testKey)`")
    lines.append("- Source: `\(test.test.sourcePath):\(test.test.funcLine)`")
    lines.append(
        "- Review directory: `\(runURL.appendingPathComponent(test.suiteKey).appendingPathComponent(test.testKey).appendingPathComponent("review").path)`"
    )
    appendExistingReviews(test.existingReviews, label: "Existing reviews", to: &lines)
    if !test.test.aiComments.isEmpty {
        lines.append("- `// AI:` comments:")
        for comment in test.test.aiComments {
            lines.append("  - \(comment.replacingOccurrences(of: "\n", with: "\n    "))")
        }
    }
    lines.append("- Source body:")
    lines.append("  ```swift")
    lines.append(indent(test.test.sourceBody, prefix: "  "))
    lines.append("  ```")
    lines.append("- Target outcomes: \(runReviewTargetOutcomeSummary(test.observations))")
    lines.append("- Attempt results:")
    for observation in test.observations {
        lines.append(
            "  - target=`\(observation.target)` attempt=`\(observation.attempt)` status=`\(observation.status.statusText)` duration=`\(observation.durationSeconds.map(formatSeconds) ?? "unknown")`"
        )
        if let detail = observation.status.detail, !detail.isEmpty {
            lines.append("    detail: \(detail.replacingOccurrences(of: "\n", with: "\n      "))")
        }
        if let recordingPath = observation.recordingPath {
            lines.append("    recording: `\(recordingPath)`")
        }
        if let shellPath = observation.shellPath {
            lines.append("    shell: `\(shellPath)`")
        }
    }
    lines.append("")
}

private func runReviewTargetOutcomeSummary(
    _ observations: [RunReviewObservation]
) -> String {
    let counts = runReviewTargetOutcomeCounts(observations)
    return
        "passed=\(counts.passed), flaked=\(counts.flaked), failed=\(counts.failed), skipped=\(counts.skipped), unknown=\(counts.unknown)"
}

private func runReviewTargetOutcomeCounts(
    _ observations: [RunReviewObservation]
) -> (passed: Int, flaked: Int, failed: Int, skipped: Int, unknown: Int) {
    var counts = (passed: 0, flaked: 0, failed: 0, skipped: 0, unknown: 0)
    for statuses in Dictionary(grouping: observations, by: \.target).values.map({ $0.map(\.status) }
    ) {
        let passed = statuses.contains { $0.statusText == "passed" }
        let failed = statuses.contains { $0.statusText == "failed" }
        let skipped = statuses.contains { $0.statusText == "skipped" }
        let unknown = statuses.contains { $0.statusText == "unknown" }
        if passed && failed {
            counts.flaked += 1
        } else if passed && !failed && !skipped && !unknown {
            counts.passed += 1
        } else if failed && !passed && !skipped && !unknown {
            counts.failed += 1
        } else if skipped && !passed && !failed && !unknown {
            counts.skipped += 1
        } else {
            counts.unknown += 1
        }
    }
    return counts
}

private func removeExistingRunReviews(in runURL: URL, reviewer: String) throws {
    removeRunReviews(in: runURL, reviewer: reviewer)
    for suiteURL in try runReviewDirectoryChildren(of: runURL) {
        guard !isE2EReviewDirectoryName(suiteURL.lastPathComponent) else { continue }
        removeRunReviews(in: suiteURL, reviewer: reviewer)
        for testURL in try runReviewDirectoryChildren(of: suiteURL) {
            removeRunReviews(in: testURL, reviewer: reviewer)
        }
    }
}

private func removeRunReviews(in directoryURL: URL, reviewer: String) {
    try? FileManager.default.removeItem(
        at: directoryURL.appendingPathComponent(e2eReviewDirectoryName(reviewer: reviewer))
    )
}

@discardableResult
private func enforceRunSuiteReviewContract(in runURL: URL, reviewer: String) throws -> Int {
    var count = 0
    for suiteURL in try runReviewDirectoryChildren(of: runURL) {
        guard !isE2EReviewDirectoryName(suiteURL.lastPathComponent) else { continue }
        count += try enforceReviews(
            in: suiteURL,
            expectedScope: "suite",
            expectedReviewer: reviewer,
            runURL: runURL
        )
        for testURL in try runReviewDirectoryChildren(of: suiteURL) {
            count += try enforceReviews(
                in: testURL,
                expectedScope: "test",
                expectedReviewer: reviewer,
                runURL: runURL
            )
        }
    }
    return count
}

private func enforceRunReportReviewContract(in runURL: URL, reviewer: String) throws {
    _ = try enforceReviews(
        in: runURL,
        expectedScope: "report",
        expectedReviewer: reviewer,
        runURL: runURL
    )
}

@discardableResult
private func enforceReviews(
    in directoryURL: URL,
    expectedScope: String,
    expectedReviewer: String,
    runURL: URL
) throws -> Int {
    let reviewURL = directoryURL.appendingPathComponent(
        e2eReviewDirectoryName(reviewer: expectedReviewer)
    )
    guard FileManager.default.fileExists(atPath: reviewURL.path) else {
        return 0
    }
    let reviewURLs = try FileManager.default.contentsOfDirectory(
        at: reviewURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension.lowercased() == "md" }

    var count = 0
    for reviewURL in reviewURLs {
        do {
            _ = try parseE2EReview(
                at: reviewURL,
                expectedScope: expectedScope,
                expectedReviewer: expectedReviewer,
                relativeTo: runURL
            )
            count += 1
        } catch {
            try? FileManager.default.removeItem(at: reviewURL)
        }
    }
    return count
}

private func defaultReviewTestsDir(packageURL: URL) -> URL {
    let e2eTestsURL = packageURL.appendingPathComponent("Tests/WendyE2ETests")
    if FileManager.default.fileExists(atPath: e2eTestsURL.path) {
        return e2eTestsURL
    }
    return packageURL.appendingPathComponent("Tests")
}

private func parseReviewTests(in testsURL: URL) throws -> [ReviewTestCase] {
    let sourceURLs = try reviewSwiftTestFiles(in: testsURL)
    var tests: [ReviewTestCase] = []

    for sourceURL in sourceURLs {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)
        var suite = sourceURL.deletingPathExtension().lastPathComponent
        var pendingTest: (line: Int, disabled: String?)?
        var discovered: [(suite: String, name: String, funcLine: Int, disabled: String?)] = []

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            if let suiteName = reviewFirstMatch(#"\bstruct\s+`([^`]+)`\s*\{"#, in: line)
                ?? reviewFirstMatch(#"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{"#, in: line)
            {
                suite = suiteName
            }
            if line.contains("@Test") {
                pendingTest = (
                    line: lineNumber,
                    disabled: reviewFirstMatch(#"\.disabled\("([^"]*)"\)"#, in: line)
                )
            }
            if let functionName = reviewFirstMatch(#"\bfunc\s+`([^`]+)`\s*\("#, in: line)
                ?? reviewFirstMatch(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#, in: line),
                let test = pendingTest
            {
                discovered.append(
                    (
                        suite: suite,
                        name: functionName,
                        funcLine: lineNumber,
                        disabled: test.disabled
                    )
                )
                pendingTest = nil
            }
        }

        for index in discovered.indices {
            let test = discovered[index]
            let nextLine =
                index + 1 < discovered.count ? discovered[index + 1].funcLine : lines.count + 1
            let bodyLines = Array(lines[(test.funcLine - 1)..<(nextLine - 1)])
            let aiComments = extractReviewAIComments(from: bodyLines)
            tests.append(
                ReviewTestCase(
                    sourcePath: sourceURL.path,
                    suite: test.suite,
                    name: test.name,
                    funcLine: test.funcLine,
                    sourceBody: bodyLines.joined(separator: "\n"),
                    aiComments: aiComments
                )
            )
        }
    }

    return tests
}

private func reviewSwiftTestFiles(in testsURL: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: testsURL.path, isDirectory: &isDirectory) else {
        throw ValidationError("Tests directory not found: \(testsURL.path)")
    }
    if !isDirectory.boolValue {
        return testsURL.lastPathComponent.hasSuffix("Tests.swift") ? [testsURL] : []
    }
    guard let enumerator = FileManager.default.enumerator(atPath: testsURL.path) else {
        throw ValidationError("Tests directory cannot be read: \(testsURL.path)")
    }
    return enumerator.compactMap { element -> URL? in
        guard let relativePath = element as? String, relativePath.hasSuffix("Tests.swift") else {
            return nil
        }
        return testsURL.appendingPathComponent(relativePath)
    }.sorted { $0.path < $1.path }
}

private func extractReviewAIComments(from lines: [String]) -> [String] {
    var blocks: [String] = []
    var currentBlock: [String] = []
    var inAI = false

    func finishBlock() {
        let block = currentBlock.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !block.isEmpty {
            blocks.append(block)
        }
        currentBlock = []
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: "// AI:") {
            if inAI {
                finishBlock()
            }
            inAI = true
            let note = trimmed[range.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            if !note.isEmpty {
                currentBlock.append(note)
            }
            continue
        }

        guard inAI else { continue }

        if trimmed.hasPrefix("//") {
            currentBlock.append(stripReviewCommentPrefix(from: trimmed))
        } else {
            finishBlock()
            inAI = false
        }
    }

    if inAI {
        finishBlock()
    }

    return blocks
}

private func stripReviewCommentPrefix(from line: String) -> String {
    var value = line
    if value.hasPrefix("//") {
        value.removeFirst(2)
    }
    if value.hasPrefix(" ") {
        value.removeFirst()
    }
    return value
}

private final class ReviewXUnitResultParser: NSObject, XMLParserDelegate {
    var results: [ReviewResultKey: ReviewTestObservation] = [:]

    private var current: (key: ReviewResultKey, failure: String?, skipped: String?, time: Double?)?
    private var currentElement: String?
    private var currentText = ""

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "testcase":
            guard let classname = attributeDict["classname"], let name = attributeDict["name"],
                let key = reviewTestResultKey(classname: classname, name: name)
            else {
                current = nil
                return
            }
            current = (
                key: key,
                failure: nil,
                skipped: nil,
                time: attributeDict["time"].flatMap(Double.init)
            )
        case "failure", "skipped":
            currentElement = elementName
            currentText = ""
            guard var current else { return }
            if elementName == "failure" {
                current.failure = attributeDict["message"] ?? ""
            } else {
                current.skipped = attributeDict["message"] ?? ""
            }
            self.current = current
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if currentElement == "failure" || currentElement == "skipped" {
            currentText.append(string)
        }
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        switch elementName {
        case "failure", "skipped":
            guard var current else { return }
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if elementName == "failure", current.failure?.isEmpty != false, !text.isEmpty {
                current.failure = text
            } else if elementName == "skipped", current.skipped?.isEmpty != false, !text.isEmpty {
                current.skipped = text
            }
            self.current = current
            currentElement = nil
            currentText = ""
        case "testcase":
            guard let current else { return }
            let status: ReviewTestStatus
            if let skipped = current.skipped {
                status = .skipped(skipped.isEmpty ? nil : skipped)
            } else if let failure = current.failure {
                status = .failed(failure.isEmpty ? nil : failure)
            } else {
                status = .passed
            }
            results[current.key] = ReviewTestObservation(
                status: status,
                durationSeconds: current.time
            )
            self.current = nil
        default:
            break
        }
    }
}

private func reviewTestResultKey(classname: String, name: String) -> ReviewResultKey? {
    let suite = reviewNormalizedClassname(classname)
    let testName = reviewNormalizedTestName(name)
    guard !suite.isEmpty, !testName.isEmpty else { return nil }
    return ReviewResultKey(suite: suite, name: testName)
}

private func reviewNormalizedClassname(_ classname: String) -> String {
    if classname.last == "`", let start = classname.dropLast().lastIndex(of: "`") {
        let suiteStart = classname.index(after: start)
        return String(classname[suiteStart..<classname.index(before: classname.endIndex)])
    }
    return reviewStripBackticks(String(classname.split(separator: ".").last ?? ""))
}

private func reviewNormalizedTestName(_ name: String) -> String {
    var value = name
    if value.hasSuffix("()") {
        value.removeLast(2)
    }
    return reviewStripBackticks(value)
}

private func reviewStripBackticks(_ value: String) -> String {
    if value.first == "`", value.last == "`" {
        return String(value.dropFirst().dropLast())
    }
    return value
}

private func reviewRelativePath(_ url: URL, base: URL) -> String {
    let path = url.path
    let basePath = base.path
    if path.hasPrefix(basePath + "/") {
        return String(path.dropFirst(basePath.count + 1))
    }
    if let range = path.range(of: "/tests/") {
        return "tests/" + path[range.upperBound...]
    }
    return path
}

private func reviewRecordFileStem(_ sourceURL: URL) -> String {
    var fileName = sourceURL.deletingPathExtension().lastPathComponent
    if fileName.hasSuffix("Tests") {
        fileName.removeLast("Tests".count)
    }
    return reviewSlug(fileName)
}

private func reviewSlug(_ value: String) -> String {
    var result = ""
    var needsSeparator = false
    var previousKind: ReviewSlugCharacterKind?
    let scalars = Array(value.unicodeScalars)

    for index in scalars.indices {
        let scalar = scalars[index]
        guard let kind = ReviewSlugCharacterKind(scalar) else {
            needsSeparator = !result.isEmpty
            previousKind = nil
            continue
        }
        let nextKind =
            scalars.index(after: index) < scalars.endIndex
            ? ReviewSlugCharacterKind(scalars[scalars.index(after: index)]) : nil
        if !result.isEmpty,
            needsSeparator
                || reviewNeedsCamelCaseSeparator(
                    previousKind: previousKind,
                    currentKind: kind,
                    nextKind: nextKind
                )
        {
            result.append("-")
        }
        result.append(String(scalar).lowercased())
        needsSeparator = false
        previousKind = kind
    }
    return result.isEmpty ? "unknown" : result
}

private func reviewNeedsCamelCaseSeparator(
    previousKind: ReviewSlugCharacterKind?,
    currentKind: ReviewSlugCharacterKind,
    nextKind: ReviewSlugCharacterKind?
) -> Bool {
    switch (previousKind, currentKind, nextKind) {
    case (.lower?, .upper, _), (.digit?, .upper, _), (.upper?, .upper, .lower?):
        true
    default:
        false
    }
}

private enum ReviewSlugCharacterKind {
    case digit
    case lower
    case upper

    init?(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 48...57:
            self = .digit
        case 65...90:
            self = .upper
        case 97...122:
            self = .lower
        default:
            return nil
        }
    }
}

private func reviewFirstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > group,
        let swiftRange = Range(match.range(at: group), in: text)
    else {
        return nil
    }
    return String(text[swiftRange])
}

private func formatSeconds(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.3f", value)
}

private func indent(_ value: String, prefix: String) -> String {
    value.components(separatedBy: .newlines).map { prefix + $0 }.joined(separator: "\n")
}
