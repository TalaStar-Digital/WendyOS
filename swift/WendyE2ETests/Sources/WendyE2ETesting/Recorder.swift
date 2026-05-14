import Foundation

public struct Recorder: Sendable {
    public let recordPath: String

    public init(
        filePath: String,
        function: String,
        line: Int
    ) throws {
        let identity = Self.testIdentity(filePath: filePath, function: function, line: line)
        self.recordPath = try Self.recordURL(identity: identity).path
        self.source = Source(
            filePath: filePath,
            fileName: identity.fileName,
            function: function,
            suite: identity.suite,
            testName: identity.testName,
            line: line
        )
    }

    public func record(
        session: Session,
        command: String,
        processIdentifier: String?,
        terminationStatus: String,
        duration: Duration,
        standardOutput: String,
        standardError: String,
        invocationCommand: String
    ) {
        do {
            let recordURL = URL(fileURLWithPath: self.recordPath, isDirectory: false)
            let recordExists = FileManager.default.fileExists(atPath: recordURL.path)

            if !recordExists {
                try Self.recordHeader(source: self.source)
                    .write(to: recordURL, atomically: true, encoding: .utf8)
            }

            let recordHandle = try FileHandle(forWritingTo: recordURL)
            defer { try? recordHandle.close() }
            try recordHandle.seekToEnd()
            try recordHandle.write(
                contentsOf: Data(
                    Self.commandRecord(
                        session: session,
                        command: command,
                        filePath: self.source.filePath,
                        line: self.source.line,
                        processIdentifier: processIdentifier,
                        terminationStatus: terminationStatus,
                        duration: duration,
                        standardOutput: standardOutput,
                        standardError: standardError
                    ).utf8
                )
            )

            try self.recordShellScript(
                session: session,
                invocationCommand: invocationCommand
            )
        } catch {
            Self.printToStandardError("Failed to write Wendy E2E command recording: \(error)\n")
        }
    }

    public static func slug(_ value: String) -> String {
        var slug = ""
        var needsSeparator = false
        var previousKind: SlugCharacterKind?
        let scalars = Array(value.unicodeScalars)

        for index in scalars.indices {
            let scalar = scalars[index]
            guard let kind = SlugCharacterKind(scalar) else {
                needsSeparator = !slug.isEmpty
                previousKind = nil
                continue
            }

            let nextKind =
                scalars.index(after: index) < scalars.endIndex
                ? SlugCharacterKind(scalars[scalars.index(after: index)]) : nil
            if !slug.isEmpty,
                needsSeparator
                    || Self.needsCamelCaseSeparator(
                        previousKind: previousKind,
                        currentKind: kind,
                        nextKind: nextKind
                    )
            {
                slug.append("-")
            }

            slug.append(String(scalar).lowercased())
            needsSeparator = false
            previousKind = kind
        }

        return slug.isEmpty ? "unknown" : slug
    }

    static func recordingFileName(filePath: String, suite: String, testName: String) -> String {
        "\(Self.fileName(from: filePath)).\(Self.slug(suite)).\(Self.slug(testName)).md"
    }

    // MARK: - Private

    private struct Source: Sendable {
        let filePath: String
        let fileName: String
        let function: String
        let suite: String
        let testName: String
        let line: Int
    }

    private struct TestIdentity: Sendable {
        let filePath: String
        let fileName: String
        let suite: String
        let testName: String
    }

    private struct TestDeclaration: Sendable {
        let suite: String
        let testName: String
        let line: Int
    }

    private enum ShellColor {
        static let reset = "\u{001B}[0m"
        static let marker = "\u{001B}[1;35m"
        static let file = "\u{001B}[1;34m"
        static let code = "\u{001B}[1;36m"
        static let text = "\u{001B}[0;37m"
        static let run = "\u{001B}[1;33m"
    }

    private let source: Source

    private static let e2eTestRecordsDirectoryName: String = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd.HH-mm-ss"

        return "e2e-recording.\(formatter.string(from: Date()))"
    }()

    private static func recordURL(identity: TestIdentity) throws -> URL {
        let directoryURL = try Self.recordsDirectoryURL()

        return directoryURL.appendingPathComponent(
            Self.recordingFileName(
                filePath: identity.filePath,
                suite: identity.suite,
                testName: identity.testName
            ),
            isDirectory: false
        )
    }

    private static func recordsDirectoryURL() throws -> URL {
        try Self.preparedRecordsDirectoryURL.get()
    }

    private static let preparedRecordsDirectoryURL: Result<URL, any Error> = Result {
        let directoryURL = Self.unpreparedRecordsDirectoryURL()
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            for url in contents {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }

        return directoryURL
    }

    private static func unpreparedRecordsDirectoryURL() -> URL {
        if let path = Environment.testRecordsDirectory {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return Self.packageRootDirectoryURL()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(Self.e2eTestRecordsDirectoryName, isDirectory: true)
    }

    private static func packageRootDirectoryURL() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()  // Sources/WendyE2ETesting
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // swift/WendyE2ETests
    }

    private static func fileName(from filePath: String) -> String {
        URL(fileURLWithPath: filePath, isDirectory: false).deletingPathExtension().lastPathComponent
    }

    private static func testIdentity(filePath: String, function: String, line: Int) -> TestIdentity
    {
        let fileName = Self.fileName(from: filePath)
        let fallbackTestName = Self.normalizedFunctionName(function)
        let fallback = TestIdentity(
            filePath: filePath,
            fileName: fileName,
            suite: fileName,
            testName: fallbackTestName
        )

        guard let source = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return fallback
        }

        let declarations = Self.testDeclarations(in: source, fallbackSuite: fileName)
        if let declaration = Self.testDeclaration(containing: line, in: declarations) {
            return TestIdentity(
                filePath: filePath,
                fileName: fileName,
                suite: declaration.suite,
                testName: declaration.testName
            )
        }

        if let declaration = declarations.last(where: { $0.testName == fallbackTestName }) {
            return TestIdentity(
                filePath: filePath,
                fileName: fileName,
                suite: declaration.suite,
                testName: declaration.testName
            )
        }

        return fallback
    }

    private static func testDeclarations(
        in source: String,
        fallbackSuite: String
    ) -> [TestDeclaration] {
        let lines = source.components(separatedBy: .newlines)
        var suite = fallbackSuite
        var pendingTest = false
        var declarations: [TestDeclaration] = []

        for (offset, line) in lines.enumerated() {
            if let suiteName = Self.suiteName(in: line) {
                suite = suiteName
            }

            if line.contains("@Test") {
                pendingTest = true
            }

            guard let testName = Self.functionName(in: line) else {
                continue
            }

            if pendingTest {
                declarations.append(
                    TestDeclaration(
                        suite: suite,
                        testName: testName,
                        line: offset + 1
                    )
                )
                pendingTest = false
            }
        }

        return declarations
    }

    private static func testDeclaration(
        containing line: Int,
        in declarations: [TestDeclaration]
    ) -> TestDeclaration? {
        for index in declarations.indices {
            let declaration = declarations[index]
            let nextLine =
                declarations.index(after: index) < declarations.endIndex
                ? declarations[declarations.index(after: index)].line : Int.max
            if declaration.line <= line, line < nextLine {
                return declaration
            }
        }

        return nil
    }

    private static func suiteName(in line: String) -> String? {
        Self.firstMatch(#"\bstruct\s+`([^`]+)`\s*\{"#, in: line)
            ?? Self.firstMatch(#"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{"#, in: line)
    }

    private static func functionName(in line: String) -> String? {
        Self.firstMatch(#"\bfunc\s+`([^`]+)`\s*\("#, in: line)
            ?? Self.firstMatch(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#, in: line)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
            let swiftRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func normalizedFunctionName(_ function: String) -> String {
        var value = function
        if value.hasSuffix("()") {
            value.removeLast(2)
        }
        if value.first == "`", value.last == "`" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func needsCamelCaseSeparator(
        previousKind: SlugCharacterKind?,
        currentKind: SlugCharacterKind,
        nextKind: SlugCharacterKind?
    ) -> Bool {
        switch (previousKind, currentKind, nextKind) {
        case (.lower?, .upper, _), (.digit?, .upper, _), (.upper?, .upper, .lower?):
            return true
        default:
            return false
        }
    }

    private static func recordHeader(source: Source) -> String {
        """
        # Wendy E2E test recording

        - Source: `\(source.filePath)`
        - Suite: `\(source.suite)`
        - Test: `\(source.testName)`
        - Function: `\(source.function)`

        """
    }

    private static func commandRecord(
        session: Session,
        command: String,
        filePath: String,
        line: Int,
        processIdentifier: String?,
        terminationStatus: String,
        duration: Duration,
        standardOutput: String,
        standardError: String
    ) -> String {
        let machine = session.machine
        let tags = machine.tags.map(\.rawValue).sorted().joined(separator: ", ")

        return """

            ---

            ## Command

            - Source: `\(filePath):\(line)`
            - Machine: `\(machine.name)`
            - Machine ID: `\(machine.id)`
            - OS: `\(machine.os.rawValue)`
            - Tags: `\(tags.isEmpty ? "<none>" : tags)`
            - User: `\(machine.user ?? "<none>")`
            - Address: `\(machine.address)`
            - Working directory: `\(machine.workingDirectory ?? "<none>")`
            - Command: `\(command)`
            - Process ID: `\(processIdentifier ?? "<unavailable>")`
            - Termination status: `\(terminationStatus)`
            - Duration: `\(duration)`

            ### environment

            ```text
            \(Self.environmentDescription(machine.env))
            ```

            ### stdout

            ```text
            \(standardOutput)
            ```

            ### stderr

            ```text
            \(standardError)
            ```

            """
    }

    private func recordShellScript(
        session: Session,
        invocationCommand: String
    ) throws {
        let scriptURL = URL(fileURLWithPath: self.recordPath, isDirectory: false)
            .deletingPathExtension()
            .appendingPathExtension("sh")
        let scriptExists = FileManager.default.fileExists(atPath: scriptURL.path)

        if !scriptExists {
            try Self.shellScriptHeader(source: self.source)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        }

        let handle = try FileHandle(forWritingTo: scriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                Self.shellScriptCommand(
                    machineName: session.machine.name,
                    invocationCommand: invocationCommand
                ).utf8
            )
        )
    }

    private static func shellScriptHeader(source: Source) -> String {
        let location = "\(source.fileName).swift:\(source.line)"
        let heading =
            ShellColor.marker + "==> " + ShellColor.file + location
            + ShellColor.text + " > " + Self.coloredDisplayName(source.suite)
            + ShellColor.text + " > " + Self.coloredDisplayName(source.testName)
            + ShellColor.reset

        return """
            #!/bin/sh

            # Replays commands captured for this Wendy E2E test recording.
            printf '%s\n' \(Self.shellQuote(heading))

            """
    }

    private static func shellScriptCommand(machineName: String, invocationCommand: String) -> String
    {
        let runLine =
            ShellColor.run + ">>> run [\(machineName)] " + invocationCommand
            + ShellColor.reset
        return """
            printf '%s\n' \(Self.shellQuote(runLine))
            \(invocationCommand)

            """
    }

    private static func coloredDisplayName(_ value: String) -> String {
        if value.first == "'", value.last == "'", value.count > 1 {
            return Self.coloredCodeSpan(String(value.dropFirst().dropLast()))
        }

        var result = ""
        var segment = ""
        var inCode = false

        func flushSegment() {
            guard !segment.isEmpty else {
                return
            }
            if inCode {
                result.append(Self.coloredCodeSpan(segment))
            } else {
                result.append(ShellColor.text + segment)
            }
            segment = ""
        }

        for character in value {
            if character == "'" {
                flushSegment()
                inCode.toggle()
            } else {
                segment.append(character)
            }
        }
        flushSegment()

        if inCode {
            result.append(ShellColor.text + "'")
        }

        return result
    }

    private static func coloredCodeSpan(_ value: String) -> String {
        ShellColor.code + "`" + value + "`" + ShellColor.text
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func environmentDescription(_ environment: [String: String]) -> String {
        guard !environment.isEmpty else {
            return "<none>"
        }

        return environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }.joined(separator: "\n")
    }

    private static func printToStandardError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }
}

private enum SlugCharacterKind {
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
