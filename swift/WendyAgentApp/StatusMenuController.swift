import AppKit
import WendyAgent

@MainActor
final class StatusMenuController: NSObject {
    init(status: WendyAgentStatus) {
        self.currentStatus = status
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        self.updateStatusButton()
        self.rebuildMenu()
    }

    func update(status: WendyAgentStatus) {
        self.currentStatus = status
        self.updateStatusButton()
        self.rebuildMenu()
    }

    func setQuitHandler(_ handler: @escaping () -> Void) {
        self.onQuit = handler
    }

    private let statusItem: NSStatusItem
    private var onQuit: (() -> Void)?
    private var currentStatus: WendyAgentStatus

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let statusItem = NSMenuItem(
            title: self.title(for: self.currentStatus),
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit WendyAgent",
            action: #selector(self.quitSelected),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    private func updateStatusButton() {
        guard let button = self.statusItem.button else { return }

        button.image = NSImage(named: NSImage.Name("StatusIcon"))
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.toolTip = "WendyAgent"
    }

    private func title(for status: WendyAgentStatus) -> String {
        switch status {
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

    @objc
    private func quitSelected() {
        self.onQuit?()
    }
}
