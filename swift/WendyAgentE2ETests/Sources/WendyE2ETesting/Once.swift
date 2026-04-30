public actor Once {
    public let name: String

    public init(name: String) {
        precondition(!name.isEmpty, "name must not be empty")

        self.name = name
    }

    public func perform(_ block: () async -> Void) async {
        guard !done else { return }
        done = true
        await block()
    }

    public func perform(_ block: () async throws -> Void) async throws {
        if let error {
            throw OnceError.failedOnFirstRun(name: self.name, originalError: error)
        }

        guard !done else { return }
        done = true

        do {
            try await block()
        } catch {
            self.error = error
            throw error
        }
    }

    // MARK: - Private

    private var done = false
    private var error: Error? = nil
}
