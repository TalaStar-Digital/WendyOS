public enum OnceError: Error {
    case failedOnFirstRun(name: String, originalError: Error)
}

// MARK: - CustomStringConvertible

extension OnceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .failedOnFirstRun(let name, let originalError):
            return "Once '\(name)' failed on first run with error: \(originalError)"
        }
    }
}
