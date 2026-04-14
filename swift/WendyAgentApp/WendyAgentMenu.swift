import AppKit
import SwiftUI
import WendyAgent

struct WendyAgentMenu: View {
    let status: WendyAgentStatus
    let onQuit: () -> Void

    var body: some View {
        Group {
            HStack(spacing: 8) {
                Circle()
                    .fill(self.statusColor)
                    .frame(width: 10, height: 10)

                Text(self.statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let message) = self.status {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Quit WendyAgent", action: self.onQuit)
                .keyboardShortcut("q")
        }
    }

    private var statusText: String {
        switch self.status {
        case .idle:
            "Idle"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .stopping:
            "Stopping"
        case .stopped:
            "Stopped"
        case .failed:
            "Failed"
        }
    }

    private var statusColor: Color {
        switch self.status {
        case .running:
            Color(nsColor: .systemGreen)
        case .starting, .stopping:
            Color(nsColor: .systemYellow)
        case .failed:
            Color(nsColor: .systemRed)
        case .idle, .stopped:
            Color(nsColor: .systemGray)
        }
    }
}

struct WendyAgentStatusItem: View {
    let status: WendyAgentStatus

    var body: some View {
        HStack {
            Image("StatusIcon")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if case .failed = self.status {
                Text("!")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 18, alignment: .leading)
        .help("WendyAgent")
    }
}
