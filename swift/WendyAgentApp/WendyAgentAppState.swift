import AppKit
import Combine
import WendyAgent

@MainActor
final class WendyAgentAppState: ObservableObject {
    enum Status: Equatable {
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .starting

    private let agent: Agent
    private var startupTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?

    init(agent: Agent = Agent()) {
        self.agent = agent
    }

    func startIfNeeded() {
        guard self.startupTask == nil else { return }

        self.startupTask = Task {
            do {
                try await self.agent.start()
                self.status = .running
            } catch {
                self.status = .failed(Self.errorMessage(for: error))
            }
        }
    }

    func quit() {
        guard self.quitTask == nil else { return }

        self.quitTask = Task {
            await self.agent.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    private static func errorMessage(for error: any Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty
        {
            return description
        }

        let description = String(describing: error)
        return description.isEmpty ? "WendyAgent failed to start." : description
    }
}
