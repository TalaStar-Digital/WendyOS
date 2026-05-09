import Foundation
import Testing
import WendyE2ETesting

@Suite
struct `reference documentation extraction` {
    @Test
    func `parses suite overview and title`() throws {
        let documents = Reference.parseSource(Self.fixtureSource, path: "DeviceInfoTests.swift")

        let document = try #require(documents.first)
        #expect(document.title == "`wendy device info`")
        #expect(document.overview.contains("Shows information reported by a Wendy agent."))
        #expect(document.overview.contains("Synopsis:"))
        #expect(document.sourceLocation.path == "DeviceInfoTests.swift")
        #expect(document.sourceLocation.line == 9)
    }

    @Test
    func `extracts mark sections in source order`() throws {
        let document = try #require(Reference.parseSource(Self.fixtureSource).first)

        #expect(
            document.sections.map(\.title) == [
                "Selecting Devices",
                "Printing Output",
            ]
        )
    }

    @Test
    func `extracts test entries into their containing sections`() throws {
        let document = try #require(Reference.parseSource(Self.fixtureSource).first)
        let selectingDevices = try #require(document.sections.first)
        let printingOutput = try #require(document.sections.dropFirst().first)

        #expect(
            selectingDevices.entries.map(\.title) == [
                "`--device` selects an explicit device",
                "uses the configured default device",
            ]
        )
        #expect(
            printingOutput.entries.map(\.title) == [
                "`--json --device` prints JSON device information"
            ]
        )
    }

    @Test
    func `extracts test documentation`() throws {
        let entry = try #require(
            Reference.parseSource(Self.fixtureSource).first?.sections.first?.entries.first
        )

        #expect(entry.documentation.contains("Selects a device explicitly with `--device`."))
        #expect(
            entry.documentation.contains("Use this form when the target device is already known.")
        )
    }

    @Test
    func `extracts disabled test state`() throws {
        let document = try #require(Reference.parseSource(Self.fixtureSource).first)
        let entries = document.sections.flatMap(\.entries)

        #expect(entries.map(\.isDisabled) == [true, true, false])
    }

    @Test
    func `parses multiple suites in one source file`() throws {
        let documents = Reference.parseSource(Self.fixtureSource)

        #expect(
            documents.map(\.title) == [
                "`wendy device info`",
                "`wendy device version`",
            ]
        )
        #expect(documents.last?.sections.first?.title == "Compatibility")
        #expect(documents.last?.sections.first?.entries.first?.title == "aliases device info")
    }

    @Test
    func `creates an overview section for tests before the first mark`() throws {
        let documents = Reference.parseSource(Self.fixtureWithoutMark)

        let document = try #require(documents.first)
        #expect(document.sections.map(\.title) == ["Overview"])
        #expect(document.sections.first?.entries.first?.title == "prints help")
    }

    @Test
    func `renders reference markdown without metadata`() throws {
        let document = try #require(Reference.parseSource(Self.fixtureSource).first)
        let markdown = Reference.renderMarkdown(document, options: .reference)

        #expect(markdown.contains("# `wendy device info`"))
        #expect(markdown.contains("## Selecting Devices"))
        #expect(markdown.contains("### `wendy device info --device` selects an explicit device"))
        #expect(markdown.contains("Selects a device explicitly with `--device`."))
        #expect(!markdown.contains("_disabled"))
        #expect(!markdown.contains("<memory>:"))
    }

    @Test
    func `renders spec review markdown with metadata`() throws {
        let document = try #require(
            Reference.parseSource(Self.fixtureSource, path: "DeviceInfoTests.swift").first
        )
        let markdown = Reference.renderMarkdown(document, options: .specReview)

        #expect(markdown.contains("_`DeviceInfoTests.swift:9`_"))
        #expect(markdown.contains("_disabled · `DeviceInfoTests.swift:18`_"))
        #expect(markdown.contains("_enabled · `DeviceInfoTests.swift:36`_"))
    }

    @Test
    func `renders multiple documents separated by a thematic break`() {
        let documents = Reference.parseSource(Self.fixtureSource)
        let markdown = Reference.renderMarkdown(documents, options: .reference)

        #expect(markdown.contains("# `wendy device info`"))
        #expect(markdown.contains("\n\n---\n\n# `wendy device version`"))
    }

    @Test
    func `dasherizes document titles for markdown file names`() {
        #expect(
            Reference.markdownFileName(forTitle: "`wendy device info`") == "wendy-device-info.md"
        )
        #expect(Reference.htmlFileName(forTitle: "`wendy device info`") == "wendy-device-info.html")
        #expect(Reference.jsonFileName(forTitle: "`wendy device info`") == "wendy-device-info.json")
        #expect(Reference.markdownFileName(forTitle: "wendy --version") == "wendy-version.md")
        #expect(
            Reference.markdownAnchor(forTitle: "`wendy device version`") == "wendy-device-version"
        )
    }

    @Test
    func `renders markdown index entries`() {
        let markdown = Reference.renderMarkdownIndex(
            Self.indexEntries(fileExtension: "md"),
            title: "Wendy E2E Reference"
        )

        #expect(markdown.contains("# Wendy E2E Reference"))
        #expect(markdown.contains("- [`wendy device info`](wendy-device-info.md)"))
        #expect(
            markdown.contains(
                "- [`wendy device version`](wendy-device-info.md#wendy-device-version)"
            )
        )
        #expect(markdown.contains("- [wendy help](wendy-help.md)"))
    }

    @Test
    func `renders html reference documents`() throws {
        let document = try #require(Reference.parseSource(Self.fixtureSource).first)
        let html = Reference.renderHTML(document, options: .reference)

        #expect(html.contains("<!doctype html>"))
        #expect(html.contains("<title>wendy device info</title>"))
        #expect(html.contains("<h1 id=\"wendy-device-info\"><code>wendy device info</code></h1>"))
        #expect(html.contains("<h2 id=\"selecting-devices\">Selecting Devices</h2>"))
        #expect(
            html.contains(
                "<h3 id=\"wendy-device-info-device-selects-an-explicit-device\"><code>wendy device info --device</code> selects an explicit device</h3>"
            )
        )
        #expect(html.contains("Selects a device explicitly with <code>--device</code>."))
    }

    @Test
    func `renders html index entries`() {
        let html = Reference.renderHTMLIndex(
            Self.indexEntries(fileExtension: "html"),
            title: "Wendy E2E Reference"
        )

        #expect(html.contains("<h1>Wendy E2E Reference</h1>"))
        #expect(
            html.contains("<a href=\"wendy-device-info.html\"><code>wendy device info</code></a>")
        )
        #expect(
            html.contains(
                "<a href=\"wendy-device-info.html#wendy-device-version\"><code>wendy device version</code></a>"
            )
        )
    }

    @Test
    func `renders json reference documents`() throws {
        let document = try #require(Reference.parseSource(Self.fixtureSource).first)
        let json = try Reference.renderJSON(document, options: .reference)

        #expect(try Self.jsonValue(from: json) is [[String: Any]])
        #expect(json.contains("\"title\" : \"`wendy device info`\""))
        #expect(json.contains("\"sections\" : ["))
        #expect(
            json.contains("\"title\" : \"`wendy device info --device` selects an explicit device\"")
        )
        #expect(!json.contains("\"sourceLocation\""))
        #expect(!json.contains("\"isDisabled\""))
    }

    @Test
    func `renders spec review json with metadata`() throws {
        let document = try #require(Reference.parseSource(Self.fixtureSource).first)
        let json = try Reference.renderJSON(document, options: .specReview)

        #expect(json.contains("\"sourceLocation\""))
        #expect(json.contains("\"isDisabled\" : true"))
    }

    @Test
    func `renders json index entries`() throws {
        let json = try Reference.renderJSONIndex(
            Self.indexEntries(fileExtension: "json"),
            title: "Wendy E2E Reference"
        )

        #expect(try Self.jsonValue(from: json) is [String: Any])
        #expect(json.contains("\"title\" : \"Wendy E2E Reference\""))
        #expect(json.contains("\"fileName\" : \"wendy-device-info.json\""))
        #expect(json.contains("\"anchor\" : \"wendy-device-version\""))
    }

    private static func jsonValue(from json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private static func indexEntries(fileExtension: String) -> [Reference.IndexEntry] {
        [
            Reference.IndexEntry(
                title: "`wendy device info`",
                fileName: "wendy-device-info.\(fileExtension)"
            ),
            Reference.IndexEntry(
                title: "`wendy device version`",
                fileName: "wendy-device-info.\(fileExtension)",
                anchor: "wendy-device-version"
            ),
            Reference.IndexEntry(title: "wendy help", fileName: "wendy-help.\(fileExtension)"),
        ]
    }

    private static let fixtureWithoutMark = """
        /**
         Shows help.
         */
        @Suite
        struct `'wendy help'` {
            /**
             Prints top-level help.
             */
            @Test(.disabled("SPEC STUB"))
            func `prints help`() async throws {
                // TODO: implement.
            }
        }
        """

    private static let fixtureSource = """
        /**
         Shows information reported by a Wendy agent.

         Synopsis:

         `wendy [--device DEVICE] device info`
         */
        @Suite(.serialized)
        struct `'wendy device info'` {
            // MARK: - Selecting Devices

            /**
             Selects a device explicitly with `--device`.

             Use this form when the target device is already known.
             */
            @Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
            func `'--device' selects an explicit device`() async throws {
                // TODO: implement.
            }

            /**
             Uses the configured default device.
             */
            @Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
            func `uses the configured default device`() async throws {
                // TODO: implement.
            }

            // MARK: - Printing Output

            /**
             Prints JSON device information.
             */
            @Test
            func `'--json --device' prints JSON device information`() async throws {
                // TODO: implement.
            }
        }

        /**
         Deprecated compatibility alias for `wendy device info`.
         */
        @Suite(.serialized)
        struct `'wendy device version'` {
            // MARK: - Compatibility

            /**
             Preserves compatibility for existing scripts.
             */
            @Test(.disabled("SPEC STUB: behavior agreed, implementation pending"))
            func `aliases device info`() async throws {
                // TODO: implement.
            }
        }
        """
}
