import AppKit
import AVFoundation
import CoreBluetooth
import OSLog
import WendyAgentCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "AppDelegate"
    )
    private let wendyAgent = WendyAgent()
    private var statusMenuController: StatusMenuController!
    private var bluetoothManager: CBCentralManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.requestPermissions()

        let statusMenuController = StatusMenuController(wendyAgent: self.wendyAgent)
        self.statusMenuController = statusMenuController

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.wendyAgent.start()
            } catch {
                self.logger.error("Failed to start WendyAgent: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    private func requestPermissions() {
        self.bluetoothManager = CBCentralManager(delegate: self, queue: nil)
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
}
