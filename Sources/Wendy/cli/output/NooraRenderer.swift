import Foundation
import Noora

/// Interactive CLI output renderer using Noora TUI library.
public struct NooraRenderer: CLIOutput, Sendable {
    public init() {}

    public func success(_ message: String) {
        Noora().success(SuccessAlert(stringLiteral: message))
    }

    public func error(_ message: String, suggestion: String?) {
        // ErrorAlert doesn't support suggestions in its string literal init,
        // so we show them separately
        Noora().error(ErrorAlert(stringLiteral: message))
        if let suggestion {
            Noora().info(InfoAlert(stringLiteral: "Suggestion: \(suggestion)"))
        }
    }

    public func info(_ message: String) {
        Noora().info(InfoAlert(stringLiteral: message))
    }

    public func warning(_ message: String) {
        Noora().warning(WarningAlert(stringLiteral: message))
    }

    public func table(headers: [String], rows: [[String]]) {
        Noora().table(headers: headers, rows: rows)
    }

    public func selectFromTable(
        title: String?,
        headers: [String],
        rows: [[String]],
        pageSize: Int
    ) async throws -> Int {
        let tableRows: [TableRow] = rows.map { row in
            row.map { TerminalText(stringLiteral: $0) }
        }

        let tableData = TableData(
            columns: headers.map { TableColumn(title: $0) },
            rows: tableRows
        )

        return try await Noora().selectableTable(tableData, pageSize: pageSize)
    }

    public func result<T: Encodable & Sendable>(_ value: T) {
        // In interactive mode, structured results are typically
        // displayed through other methods (table, info, etc.)
        // If a command only calls result(), fall back to JSON display
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value),
           let string = String(data: data, encoding: .utf8)
        {
            print(string)
        }
    }

    public func progress(message: String, percent: Double?) {
        // For simple progress, just show info
        let text: String
        if let percent {
            text = "[\(Int(percent * 100))%] \(message)"
        } else {
            text = message
        }
        Noora().info(InfoAlert(stringLiteral: text))
    }

    public func withProgress<T: Sendable>(
        message: String,
        successMessage: String,
        errorMessage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Noora().progressStep(
            message: message,
            successMessage: successMessage,
            errorMessage: errorMessage,
            showSpinner: true
        ) { _ in
            try await operation()
        }
    }

    public func withProgressBar<T: Sendable>(
        message: String,
        operation: @escaping @Sendable (@escaping (Double) -> Void) async throws -> T
    ) async throws -> T {
        try await Noora().progressBarStep(message: message) { updateProgress in
            try await operation(updateProgress)
        }
    }

    public func withStreamingOutput<T: Sendable>(
        title: String,
        maxLines: Int,
        operation: @escaping @Sendable (@escaping @Sendable (String) async -> Void) async throws -> T
    ) async throws -> T {
        // Create temp file for full output
        let tempDir = FileManager.default.temporaryDirectory
        let logFile = tempDir.appendingPathComponent("wendy-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: logFile)

        let box = BorderedBox(title: title, width: 80, height: maxLines)
        await box.printTop()

        do {
            let value = try await operation { line in
                // Write to temp file
                if let data = (line + "\n").data(using: .utf8) {
                    try? fileHandle.write(contentsOf: data)
                }

                // Split on newlines in case multiple lines are passed at once
                for part in line.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        await box.addLine(trimmed)
                    }
                }
            }
            await box.finish()
            try? fileHandle.close()
            Noora().info(InfoAlert(stringLiteral: "Full output: \(logFile.path)"))
            return value
        } catch {
            await box.finish()
            try? fileHandle.close()
            Noora().info(InfoAlert(stringLiteral: "Full output: \(logFile.path)"))
            throw error
        }
    }
}

/// A fixed-size bordered box that redraws in place for streaming terminal output.
/// Uses an actor to ensure thread-safe access from concurrent stdout/stderr streams.
private actor BorderedBox {
    let title: String
    let width: Int
    let height: Int
    private var lines: [String] = []
    private var hasDrawn = false

    init(title: String, width: Int, height: Int) {
        self.title = title
        self.width = width
        self.height = height
    }

    func printTop() {
        // ┌─ Title ─────────┐
        let titlePart = "─ \(title) "
        let remaining = max(0, width - titlePart.count - 2)
        print("┌\(titlePart)\(String(repeating: "─", count: remaining))┐")

        // Print empty box initially
        for _ in 0..<height {
            printPaddedLine("")
        }
        printBottomBorder()
        hasDrawn = true
    }

    func addLine(_ text: String) {
        lines.append(text)
        if lines.count > height {
            lines.removeFirst()
        }
        redraw()
    }

    private func redraw() {
        guard hasDrawn else { return }

        // Move cursor up (height + 1 for bottom border)
        print("\u{1B}[\(height + 1)A", terminator: "")

        // Redraw all lines
        for i in 0..<height {
            if i < lines.count {
                printPaddedLine(lines[i])
            } else {
                printPaddedLine("")
            }
        }
        printBottomBorder()

        // Flush output
        fflush(stdout)
    }

    private func printPaddedLine(_ text: String) {
        let contentWidth = width - 4  // Account for "│ " and " │"
        let displayText: String
        if text.count > contentWidth {
            displayText = String(text.prefix(contentWidth - 1)) + "…"
        } else {
            displayText = text + String(repeating: " ", count: contentWidth - text.count)
        }
        print("│ \(displayText) │")
    }

    private func printBottomBorder() {
        print("└\(String(repeating: "─", count: width - 2))┘")
    }

    func finish() {
        guard hasDrawn else { return }
        // Move cursor up and clear the box area
        print("\u{1B}[\(height + 2)A", terminator: "")  // +2 for top and bottom borders
        for _ in 0..<(height + 2) {
            print("\u{1B}[2K")  // Clear entire line
        }
        // Move cursor back up to where the box started
        print("\u{1B}[\(height + 2)A", terminator: "")
        fflush(stdout)
    }
}
