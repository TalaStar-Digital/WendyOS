import Foundation

enum AgentVersion {
    static let environmentVariable = "WENDY_AGENT_VERSION"
    static let fallback = "0.0.0-dev"

    static var current: String {
        self.resolve(
            bundleInfo: Bundle.main.infoDictionary,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func resolve(
        bundleInfo: [String: Any]?,
        environment: [String: String]
    ) -> String {
        if let bundleVersion = self.usableVersion(from: bundleInfo?["CFBundleShortVersionString"] as? String)
        {
            return bundleVersion
        }

        if let bundleBuildVersion = self.usableVersion(from: bundleInfo?["CFBundleVersion"] as? String) {
            return bundleBuildVersion
        }

        if let environmentVersion = self.usableVersion(from: environment[self.environmentVariable]) {
            return environmentVersion
        }

        return self.fallback
    }

    private static func usableVersion(from candidate: String?) -> String? {
        guard let candidate else { return nil }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case self.fallback, "0000.00.00", "00000000000000":
            return nil
        default:
            return trimmed
        }
    }
}
