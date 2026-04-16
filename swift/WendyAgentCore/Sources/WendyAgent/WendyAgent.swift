import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCServiceLifecycle
import Logging
import OpenTelemetryGRPC
import ServiceLifecycle
import WendyAgentGRPC

@MainActor
public final class WendyAgent {
    private typealias PosixGRPCServer = GRPCServer<HTTP2ServerTransport.Posix>

    private struct MainServerRuntime {
        let server: PosixGRPCServer
    }

    private struct OTelServerRuntime {
        let server: PosixGRPCServer
    }

    private struct BonjourRuntime {
        let advertiser: BonjourAdvertiser
    }

    public let configuration: WendyAgentConfiguration
    public private(set) var status: WendyAgentStatus = .idle

    public init(configuration: WendyAgentConfiguration = .init()) {
        self.configuration = configuration
    }

    public func start() async throws {
        guard self.runTask == nil else { return }

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

        do {
            self.logger.info("Startup stage: telemetry broadcaster initialization")
            let dockerAvailable = await self.prepareDockerIfNeeded()
            let mainServerRuntime = try await self.startMainServer(
                dockerAvailable: dockerAvailable,
                broadcaster: broadcaster
            )
            let otelServerRuntime = try await self.startOTelServer(broadcaster: broadcaster)
            let bonjourRuntime = try await self.startBonjour()

            self.logger.info("Startup stage: service group creation")
            let serviceGroup = self.makeServiceGroup(
                mainServerRuntime: mainServerRuntime,
                otelServerRuntime: otelServerRuntime,
                bonjourRuntime: bonjourRuntime
            )

            self.logger.info("Startup stage: service group launch")
            let runTask = Self.makeRunTask(serviceGroup: serviceGroup)

            self.runIdentifier &+= 1
            let runIdentifier = self.runIdentifier
            self.mainServerRuntime = mainServerRuntime
            self.otelServerRuntime = otelServerRuntime
            self.bonjourRuntime = bonjourRuntime
            self.serviceGroup = serviceGroup
            self.runTask = runTask
            self.startMonitorTask(runTask: runTask, runIdentifier: runIdentifier)

            self.logger.info(
                "Listening on port \(self.configuration.port), OTel on port \(self.configuration.otelPort)"
            )

            self.logger.info("Startup stage: status transition to running")
            guard self.runIdentifier == runIdentifier, self.runTask != nil else { return }
            self.updateStatus(.running)
            self.logger.info("Startup complete: Wendy Agent is running")
        } catch {
            await self.rollback()
            throw error
        }
    }

    public func stop() async {
        guard let serviceGroup, let runTask else {
            return
        }

        self.updateStatus(.stopping)

        await serviceGroup.triggerGracefulShutdown()

        do {
            try await runTask.value
            self.finalizeRunTaskIfNeeded(runIdentifier: self.runIdentifier, error: nil)
        } catch {
            self.finalizeRunTaskIfNeeded(runIdentifier: self.runIdentifier, error: error)
        }
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
    private var serviceGroup: ServiceGroup?
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

        return MainServerRuntime(server: server)
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

        return OTelServerRuntime(server: server)
    }

    private func startBonjour() async throws -> BonjourRuntime {
        self.logger.info("Startup stage: Bonjour advertiser creation")
        let advertiser = BonjourAdvertiser(
            port: self.configuration.port,
            displayName: ProcessInfo.processInfo.hostName,
            deviceID: ProcessInfo.processInfo.hostName
        )

        return BonjourRuntime(advertiser: advertiser)
    }

    private func startMonitorTask(runTask: Task<Void, Error>, runIdentifier: UInt64) {
        self.monitorTask?.cancel()
        self.monitorTask = Task {
            await self.monitorRunTask(runTask, runIdentifier: runIdentifier)
        }
    }

    private func rollback() async {
        self.clearRuntimeState()
    }

    private func clearRuntimeState() {
        self.mainServerRuntime = nil
        self.otelServerRuntime = nil
        self.bonjourRuntime = nil
        self.serviceGroup = nil
        self.runTask = nil
        self.monitorTask?.cancel()
        self.monitorTask = nil
    }

    private func makeServiceGroup(
        mainServerRuntime: MainServerRuntime,
        otelServerRuntime: OTelServerRuntime,
        bonjourRuntime: BonjourRuntime
    ) -> ServiceGroup {
        ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: mainServerRuntime.server),
                    .init(service: otelServerRuntime.server),
                    .init(service: bonjourRuntime.advertiser),
                ],
                logger: self.logger
            )
        )
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

    nonisolated private static func makeRunTask(serviceGroup: ServiceGroup) -> Task<Void, Error> {
        Task {
            try await serviceGroup.run()
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
