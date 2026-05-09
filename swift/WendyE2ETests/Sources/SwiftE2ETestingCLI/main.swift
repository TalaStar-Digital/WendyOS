import ArgumentParser
import Foundation
import WendyE2ETesting

@main
struct SwiftE2ETestingCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-e2e-testing",
        abstract: "Utilities for Swift E2E behavioral specs.",
        subcommands: [ReferenceCommand.self]
    )
}

struct ReferenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reference",
        abstract: "Generate Markdown reference documentation from Swift E2E tests.",
        discussion: """
            Each path may be a Swift test file or a directory containing Swift test files.
            Without --output, all generated Markdown is written to stdout. With --output,
            one Markdown file is written per Swift test file, along with an index.md.
            """
    )

    @Flag(help: "Include Given/When/Then requirement comments.")
    var includeRequirements = false

    @Flag(help: "Include source file and line metadata.")
    var includeSourceLocations = false

    @Flag(help: "Include enabled/disabled test metadata.")
    var includeDisabledState = false

    @Flag(help: "Include requirements, source locations, and disabled state.")
    var specReview = false

    @Option(name: [.short, .long], help: "Write Markdown files and index.md to this directory.")
    var output: String?

    @Argument(help: "Swift test files or directories containing Swift test files.")
    var paths: [String] = []

    mutating func run() throws {
        guard !paths.isEmpty else {
            throw ValidationError("Missing path.")
        }

        let options = Reference.MarkdownOptions(
            includeRequirements: includeRequirements || specReview,
            includeSourceLocations: includeSourceLocations || specReview,
            includeDisabledState: includeDisabledState || specReview
        )
        let sourceFiles = try paths.flatMap(referenceSourceFiles)

        if let output {
            let fileCount = try writeReferenceFiles(
                sourceFiles: sourceFiles,
                outputDirectory: output,
                options: options
            )
            print("Wrote \(fileCount) reference file(s) to \(output)")
            return
        }

        var documents: [Reference.Document] = []
        for sourceFile in sourceFiles {
            documents.append(contentsOf: try Reference.parseFile(at: sourceFile))
        }
        print(Reference.renderMarkdown(documents, options: options), terminator: "")
    }
}

private func writeReferenceFiles(
    sourceFiles: [String],
    outputDirectory: String,
    options: Reference.MarkdownOptions
) throws -> Int {
    let outputURL = URL(fileURLWithPath: outputDirectory)
    try FileManager.default.createDirectory(
        at: outputURL,
        withIntermediateDirectories: true
    )

    var fileCount = 0
    var indexEntries: [Reference.IndexEntry] = []
    for sourceFile in sourceFiles {
        let documents = try Reference.parseFile(at: sourceFile)
        guard let topLevelDocument = documents.first else {
            continue
        }

        let fileName = Reference.markdownFileName(forTitle: topLevelDocument.title)
        let markdown = Reference.renderMarkdown(documents, options: options)
        try markdown.write(
            to: outputURL.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
        fileCount += 1
        for (documentIndex, document) in documents.enumerated() {
            indexEntries.append(
                Reference.IndexEntry(
                    title: document.title,
                    fileName: fileName,
                    anchor: documentIndex == 0
                        ? nil : Reference.markdownAnchor(forTitle: document.title)
                )
            )
        }
    }

    let indexMarkdown = Reference.renderMarkdownIndex(
        indexEntries,
        title: "Wendy E2E Reference"
    )
    try indexMarkdown.write(
        to: outputURL.appendingPathComponent("index.md"),
        atomically: true,
        encoding: .utf8
    )

    return fileCount
}

private func referenceSourceFiles(for path: String) throws -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw ValidationError("Path not found: \(path)")
    }

    if !isDirectory.boolValue {
        return [path]
    }

    guard let enumerator = FileManager.default.enumerator(atPath: path) else {
        throw ValidationError("Directory cannot be read: \(path)")
    }

    return enumerator.compactMap { element -> String? in
        guard let relativePath = element as? String, relativePath.hasSuffix(".swift") else {
            return nil
        }
        return URL(fileURLWithPath: path).appendingPathComponent(relativePath).path
    }.sorted()
}
