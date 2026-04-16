import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import OpenTelemetryGRPC
import WendyAgentGRPC

@MainActor
public final class WendyAgent {
    private typealias PosixGRPCServer = GRPCServer<HTTP2ServerTransport.Posix>

    private struct MainServerRuntime {
        let server: PosixGRPCServer
        let task: Task<Void, Error>
    }

    private struct OTelServerRuntime {
        let server: PosixGRPCServer
        let task: Task<Void, Error>
    }

    private struct BonjourRuntime {
        let registration: BonjourRegistration
        let task: Task<Void, Error>
    }

    public let configuration: WendyAgentConfiguration
    public private(set) var status: WendyAgentStatus = .idle

    public init(configuration: WendyAgentConfiguration = .init()) {
        self.configuration = configuration
    }

    public func start() async throws {
        switch self.status {
        case .idle, .stopped, .failed:
            break
        case .starting, .running, .stopping:
            return
        }

        Self.bootstrapLogging
        self.updateStatus(.starting)

        self.logger.info(
            "Starting Wendy Agent",
            metadata: [
                "grpc_port": "\(self.configuration.port)",
                "otel_port": "\(self.configuration.otelPort)",
            ]
        )

        let broadcaster = TelemetryBroadcaster()
        var mainServerRuntime: MainServerRuntime?
        var otelServerRuntime: OTelServerRuntime?
        var bonjourRuntime: BonjourRuntime?

        do {
            self.logger.info("Startup stage: telemetry broadcaster initialization")
            let dockerAvailable = await self.prepareDockerIfNeeded()

            let startedMainServerRuntime = try await self.startMainServer(
                dockerAvailable: dockerAvailable,
                broadcaster: broadcaster
            )
            mainServerRuntime = startedMainServerRuntime

            let startedOTelServerRuntime = try await self.startOTelServer(broadcaster: broadcaster)
            otelServerRuntime = startedOTelServerRuntime

            let startedBonjourRuntime = try await self.startBonjour()
            bonjourRuntime = startedBonjourRuntime

            self.runIdentifier &+= 1
            let runIdentifier = self.runIdentifier
            self.mainServerRuntime = startedMainServerRuntime
            self.otelServerRuntime = startedOTelServerRuntime
            self.bonjourRuntime = startedBonjourRuntime
            self.runTask = startedBonjourRuntime.task
            self.startMonitorTask(runTask: startedBonjourRuntime.task, runIdentifier: runIdentifier)

            self.logger.info(
                "Listening on port \(self.configuration.port), OTel on port \(self.configuration.otelPort)"
            )

            self.logger.info("Startup stage: status transition to running")
            guard self.runIdentifier == runIdentifier, self.runTask != nil else { return }
            self.updateStatus(.running)
            self.logger.info("Startup complete: Wendy Agent is running")
        } catch {
            await self.rollback(
                mainServerRuntime: mainServerRuntime,
                otelServerRuntime: otelServerRuntime,
                bonjourRuntime: bonjourRuntime
            )
            throw error
        }
    }

    public func stop() async {
        guard case .running = self.status else {
            return
        }

        guard let mainServerRuntime = self.mainServerRuntime,
              let otelServerRuntime = self.otelServerRuntime,
              let bonjourRuntime = self.bonjourRuntime
        else {
            self.clearRuntimeState()
            self.updateStatus(.stopped)
            return
        }

        self.updateStatus(.stopping)
        self.runTask = nil
        self.monitorTask?.cancel()
        self.monitorTask = nil

        mainServerRuntime.server.beginGracefulShutdown()
        otelServerRuntime.server.beginGracefulShutdown()
        await bonjourRuntime.registration.shutdown()

        _ = try? await mainServerRuntime.task.value
        _ = try? await otelServerRuntime.task.value
        _ = try? await bonjourRuntime.task.value

        self.clearRuntimeState()
        self.updateStatus(.stopped)
    }

    public func observeStatus(
        _ handler: @escaping @isolated(any) @Sendable (WendyAgentStatus) -> Void
    ) -> WendyObservation {
        let observationID = self.statusObservationRegistry.register(handler, initialValue: self.status)
        self.scheduleStatusObservation(for: observationID)

        return WendyObservation { [self] in
            await self.cancelStatusObservation(for: observationID)
        }
    }

    // MARK: - Private

    private static let bootstrapLogging: Void = {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }
    }()

    private let logger = Logger(label: "sh.wendy.agent")

    private var mainServerRuntime: MainServerRuntime?
    private var otelServerRuntime: OTelServerRuntime?
    private var bonjourRuntime: BonjourRuntime?
    private var runTask: Task<Void, Error>?
    private var monitorTask: Task<Void, Never>?
    private var runIdentifier: UInt64 = 0
    private var statusObservationRegistry = WendyObservationRegistry<WendyAgentStatus>(areEquivalent: ==)
    private var statusObservationTasks: [WendyObservationRegistry<WendyAgentStatus>.ObservationID: Task<Void, Never>] = [:]

    private func prepareDockerIfNeeded() async -> Bool {
        let docker = DockerCLI()

        self.logger.info("Startup stage: Docker availability probe")
        let dockerAvailable = await docker.checkAvailable()
        if dockerAvailable {
            self.logger.info(
                "Startup stage: Docker local registry startup",
                metadata: ["registry_port": "\(DockerCLI.registryPort)"]
            )
            do {
                try await docker.ensureRegistry()
                self.logger.info("Startup stage complete: Docker local registry startup")
            } catch {
                self.logger.warning(
                    "Failed to start Docker registry: \(String(describing: error)). Linux container support disabled."
                )
            }
        } else {
            self.logger.info("Docker not available, Linux container support disabled")
        }

        return dockerAvailable
    }

    private func startMainServer(
        dockerAvailable: Bool,
        broadcaster: TelemetryBroadcaster
    ) async throws -> MainServerRuntime {
        self.logger.info("Startup stage: application support path setup")
        let appsBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/wendy-agent/apps")

        self.logger.info("Startup stage: main Wendy Agent gRPC service construction")
        let services: [any RegistrableRPCService] = [
            AgentService(),
            ContainerService(
                broadcaster: broadcaster,
                executablePath: self.configuration.appPath,
                sandboxProfilePath: self.configuration.sandboxProfile.isEmpty
                    ? nil
                    : self.configuration.sandboxProfile,
                appsBase: appsBase,
                dockerAvailable: dockerAvailable
            ),
            AudioService(),
            ProvisioningService(),
            TelemetryService(broadcaster: broadcaster),
            FileSyncService(appsBase: appsBase),
        ]

        self.logger.info(
            "Startup stage: main Wendy Agent gRPC server creation",
            metadata: ["grpc_port": "\(self.configuration.port)"]
        )
        let server = PosixGRPCServer(
            transport: HTTP2ServerTransport.Posix(
                address: .ipv6(host: "::", port: self.configuration.port),
                transportSecurity: .plaintext
            ),
            services: services
        )

        self.logger.info("Startup stage: main Wendy Agent gRPC server launch")
        let task = Self.makeServeTask(server: server)

        do {
            if let address = try await server.listeningAddress {
                self.logger.info("Startup stage complete: main Wendy Agent gRPC server listening", metadata: [
                    "grpc_address": "\(address)"
                ])
            } else {
                self.logger.info("Startup stage complete: main Wendy Agent gRPC server listening")
            }

            return MainServerRuntime(server: server, task: task)
        } catch {
            server.beginGracefulShutdown()
            _ = try? await task.value
            throw error
        }
    }

    private func startOTelServer(
        broadcaster: TelemetryBroadcaster
    ) async throws -> OTelServerRuntime {
        self.logger.info("Startup stage: local OpenTelemetry gRPC service construction")
        let services: [any RegistrableRPCService] = [
            LocalOTelLogsReceiver(broadcaster: broadcaster),
            LocalOTelMetricsReceiver(broadcaster: broadcaster),
            LocalOTelTracesReceiver(broadcaster: broadcaster),
        ]

        self.logger.info(
            "Startup stage: local OpenTelemetry gRPC server creation",
            metadata: ["otel_port": "\(self.configuration.otelPort)"]
        )
        let server = PosixGRPCServer(
            transport: HTTP2ServerTransport.Posix(
                address: .ipv4(host: "127.0.0.1", port: self.configuration.otelPort),
                transportSecurity: .plaintext
            ),
            services: services
        )

        self.logger.info("Startup stage: local OpenTelemetry gRPC server launch")
        let task = Self.makeServeTask(server: server)

        do {
            if let address = try await server.listeningAddress {
                self.logger.info("Startup stage complete: local OpenTelemetry gRPC server listening", metadata: [
                    "otel_address": "\(address)"
                ])
            } else {
                self.logger.info("Startup stage complete: local OpenTelemetry gRPC server listening")
            }

            return OTelServerRuntime(server: server, task: task)
        } catch {
            server.beginGracefulShutdown()
            _ = try? await task.value
            throw error
        }
    }

    private func startBonjour() async throws -> BonjourRuntime {
        self.logger.info("Startup stage: Bonjour advertiser creation")
        let advertiser = BonjourAdvertiser(
            port: self.configuration.port,
            displayName: ProcessInfo.processInfo.hostName,
            deviceID: ProcessInfo.processInfo.hostName
        )

        self.logger.info("Startup stage: Bonjour advertisement registration")
        let runtime = try await advertiser.start()
        self.logger.info("Startup stage complete: Bonjour advertisement registered")

        return BonjourRuntime(registration: runtime.registration, task: runtime.task)
    }

    private func startMonitorTask(runTask: Task<Void, Error>, runIdentifier: UInt64) {
        self.monitorTask?.cancel()
        self.monitorTask = Task {
            await self.monitorRunTask(runTask, runIdentifier: runIdentifier)
        }
    }

    private func rollback(
        mainServerRuntime: MainServerRuntime?,
        otelServerRuntime: OTelServerRuntime?,
        bonjourRuntime: BonjourRuntime?
    ) async {
        mainServerRuntime?.server.beginGracefulShutdown()
        otelServerRuntime?.server.beginGracefulShutdown()
        await bonjourRuntime?.registration.shutdown()

        _ = try? await bonjourRuntime?.task.value
        _ = try? await mainServerRuntime?.task.value
        _ = try? await otelServerRuntime?.task.value

        self.clearRuntimeState()
    }

    private func clearRuntimeState() {
        self.mainServerRuntime = nil
        self.otelServerRuntime = nil
        self.bonjourRuntime = nil
        self.runTask = nil
        self.monitorTask?.cancel()
        self.monitorTask = nil
    }

    private func monitorRunTask(_ runTask: Task<Void, Error>, runIdentifier: UInt64) async {
        do {
            try await runTask.value
            self.finalizeRunTaskIfNeeded(runIdentifier: runIdentifier, error: nil)
        } catch {
            self.finalizeRunTaskIfNeeded(runIdentifier: runIdentifier, error: error)
        }
    }

    private func finalizeRunTaskIfNeeded(runIdentifier: UInt64, error: (any Error)?) {
        guard self.runIdentifier == runIdentifier, self.runTask != nil else { return }

        self.clearRuntimeState()

        switch self.status {
        case .stopping:
            self.updateStatus(.stopped)
        case .starting, .running:
            if let error {
                self.updateStatus(.failed(Self.errorMessage(for: error)))
            } else {
                self.updateStatus(.stopped)
            }
        case .idle, .stopped, .failed:
            break
        }
    }

    private func updateStatus(_ status: WendyAgentStatus) {
        self.status = status

        let observationIDs = self.statusObservationRegistry.enqueue(status)
        for observationID in observationIDs {
            self.scheduleStatusObservation(for: observationID)
        }
    }

    private func scheduleStatusObservation(
        for observationID: WendyObservationRegistry<WendyAgentStatus>.ObservationID
    ) {
        guard self.statusObservationTasks[observationID] == nil else { return }

        let task = Task { @MainActor in
            await self.runStatusObservation(for: observationID)
        }
        self.statusObservationTasks[observationID] = task
    }

    private func runStatusObservation(
        for observationID: WendyObservationRegistry<WendyAgentStatus>.ObservationID
    ) async {
        while let delivery = self.statusObservationRegistry.beginDelivery(for: observationID) {
            await delivery.handler(delivery.value)

            let shouldContinue = self.statusObservationRegistry.finishDelivery(
                for: observationID,
                delivered: delivery.value
            )
            guard shouldContinue else { break }
        }

        self.statusObservationTasks.removeValue(forKey: observationID)
    }

    private func cancelStatusObservation(
        for observationID: WendyObservationRegistry<WendyAgentStatus>.ObservationID
    ) async {
        self.statusObservationRegistry.removeObservation(observationID)
        let task = self.statusObservationTasks.removeValue(forKey: observationID)
        await task?.value
    }

    nonisolated private static func makeServeTask(server: PosixGRPCServer) -> Task<Void, Error> {
        Task {
            try await server.serve()
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
