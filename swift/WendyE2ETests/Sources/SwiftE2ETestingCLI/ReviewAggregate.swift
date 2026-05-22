import Foundation

func writeE2EReviewAggregate(in runURL: URL) throws {
    let issues = try loadE2EReviewAggregateIssues(in: runURL)
    let markdown = renderE2EReviewAggregate(issues: issues)
    let outputURL = runURL.appendingPathComponent("review.md")
    try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
    print("==> Wrote Swift E2E review aggregate")
    print("    Review: \(outputURL.path)")
}

private struct E2EReviewAggregateIssue {
    var scope: E2EReviewAggregateScope
    var suiteKey: String?
    var testKey: String?
    var review: E2EReview

    var severity: E2EReviewSeverity {
        review.metadata.severity
    }
}

private enum E2EReviewAggregateScope: Int {
    case report = 0
    case suite = 1
    case test = 2

    var summaryTitle: String {
        switch self {
        case .report:
            "run"
        case .suite:
            "suite"
        case .test:
            "test"
        }
    }
}

private func loadE2EReviewAggregateIssues(in runURL: URL) throws -> [E2EReviewAggregateIssue] {
    var issues = try loadE2EReviews(
        in: runURL,
        expectedScope: "report",
        relativeTo: runURL
    ).map { review in
        E2EReviewAggregateIssue(scope: .report, suiteKey: nil, testKey: nil, review: review)
    }

    for suiteURL in try reviewAggregateDirectoryChildren(of: runURL) {
        let suiteKey = suiteURL.lastPathComponent
        guard !isE2EReviewDirectoryName(suiteKey) else { continue }

        issues += try loadE2EReviews(
            in: suiteURL,
            expectedScope: "suite",
            relativeTo: runURL
        ).map { review in
            E2EReviewAggregateIssue(scope: .suite, suiteKey: suiteKey, testKey: nil, review: review)
        }

        for testURL in try reviewAggregateDirectoryChildren(of: suiteURL) {
            let testKey = testURL.lastPathComponent
            guard !isE2EReviewDirectoryName(testKey) else { continue }

            issues += try loadE2EReviews(
                in: testURL,
                expectedScope: "test",
                relativeTo: runURL
            ).map { review in
                E2EReviewAggregateIssue(scope: .test, suiteKey: suiteKey, testKey: testKey, review: review)
            }
        }
    }

    return issues.sorted { lhs, rhs in
        if lhs.severity.sortRank != rhs.severity.sortRank {
            return lhs.severity.sortRank < rhs.severity.sortRank
        }
        if lhs.scope.rawValue != rhs.scope.rawValue {
            return lhs.scope.rawValue < rhs.scope.rawValue
        }
        if lhs.suiteKey != rhs.suiteKey {
            return (lhs.suiteKey ?? "") < (rhs.suiteKey ?? "")
        }
        if lhs.testKey != rhs.testKey {
            return (lhs.testKey ?? "") < (rhs.testKey ?? "")
        }
        return lhs.review.path < rhs.review.path
    }
}

private func renderE2EReviewAggregate(issues: [E2EReviewAggregateIssue]) -> String {
    var lines: [String] = [
        "# Swift E2E Review",
        "",
        "<!-- wendy-e2e-review-aggregate:v1 -->",
        "",
    ]

    guard !issues.isEmpty else {
        lines.append("No Swift E2E review issues were generated for this run.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    lines.append("Found **\(issues.count) review issue\(issues.count == 1 ? "" : "s")**: \(reviewAggregateSeveritySummary(issues)).")
    lines.append("")
    lines.append("Reviewers: \(reviewAggregateReviewers(issues))")
    lines.append("")

    for issue in issues {
        appendE2EReviewAggregateIssue(issue, to: &lines)
    }

    return lines.joined(separator: "\n")
}

private func reviewAggregateSeveritySummary(_ issues: [E2EReviewAggregateIssue]) -> String {
    let severities: [E2EReviewSeverity] = [.fail, .concern, .info]
    let parts = severities.compactMap { severity -> String? in
        let count = issues.filter { $0.severity == severity }.count
        guard count > 0 else { return nil }
        return "\(count) \(severity.pluralizedLabel(count: count))"
    }
    return parts.joined(separator: ", ")
}

private func reviewAggregateReviewers(_ issues: [E2EReviewAggregateIssue]) -> String {
    let reviewers = Set(issues.map { $0.review.metadata.reviewer }).sorted()
    return reviewers.map { "`\($0)`" }.joined(separator: ", ")
}

private func appendE2EReviewAggregateIssue(
    _ issue: E2EReviewAggregateIssue,
    to lines: inout [String]
) {
    let review = issue.review
    lines.append(reviewAggregateTitleLine(for: issue))
    lines.append("")
    lines.append(review.summaryMarkdown)
    lines.append("")
    lines.append("<details>")
    lines.append("<summary>Details</summary>")
    lines.append("")
    lines.append(review.detailsMarkdown)
    lines.append("")
    appendE2EReviewAggregateMetadata(issue, to: &lines)
    lines.append("")
    lines.append("</details>")
    lines.append("")
}

private func reviewAggregateTitleLine(for issue: E2EReviewAggregateIssue) -> String {
    let severity = issue.severity
    var parts = [
        severity.rawValue,
        issue.scope.summaryTitle,
    ]
    if let scopePath = reviewAggregateScopePath(for: issue) {
        parts.append("`\(scopePath)`")
    }
    let prefix = parts.joined(separator: " · ")
    return "## \(prefix) — \(reviewAggregateSingleLine(issue.review.title))"
}

private func appendE2EReviewAggregateMetadata(
    _ issue: E2EReviewAggregateIssue,
    to lines: inout [String]
) {
    let review = issue.review
    lines.append("- Reviewer: `\(review.metadata.reviewer)`")
    if let confidence = review.metadata.confidence, !confidence.isEmpty {
        lines.append("- Confidence: `\(confidence)`")
    }
    if let locations = review.metadata.locations, !locations.isEmpty {
        lines.append("- Locations: \(reviewAggregateLocations(locations))")
    }
    lines.append("- Full review: `\(review.path)`")
}

private func reviewAggregateScopePath(for issue: E2EReviewAggregateIssue) -> String? {
    switch issue.scope {
    case .report:
        nil
    case .suite:
        issue.suiteKey
    case .test:
        [issue.suiteKey, issue.testKey].compactMap { $0 }.joined(separator: "/")
    }
}

private func reviewAggregateLocations(_ locations: [E2EReviewLocation]) -> String {
    locations.map { location in
        var value = "\(location.path):\(location.startLine)"
        if let endLine = location.endLine, endLine != location.startLine {
            value += "-\(endLine)"
        }
        return "`\(value)`"
    }.joined(separator: ", ")
}

private func reviewAggregateDirectoryChildren(of url: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    .filter { child in
        ((try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func reviewAggregateSingleLine(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
