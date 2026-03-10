import ArgumentParser
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCServiceLifecycle
import Logging
import ServiceLifecycle
import WendyAgentGRPC

@main
struct WendyAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wendy-agent",
        abstract: "Wendy Agent"
    )

    @Option(name: .shortAndLong, help: "The port to listen on for incoming connections.")
    var port: Int = 50051

    @Option(name: .shortAndLong, help: "The directory to store configuration files in.")
    var configDir: String = "/etc/wendy-agent"

    func run() async throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }

        let logger = Logger(label: "sh.wendy.agent")
        logger.info("Starting Wendy Agent on port \(port)")

        let services: [any RegistrableRPCService] = [
            AgentService(),
            ContainerService(),
            AudioService(),
            ProvisioningService(),
            TelemetryService(),
        ]

        let server = GRPCServer(
            transport: HTTP2ServerTransport.Posix(
                address: .ipv6(host: "::", port: port),
                transportSecurity: .plaintext
            ),
            services: services
        )

        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [.init(service: server)],
                gracefulShutdownSignals: [.sigint, .sigterm],
                logger: logger
            )
        )

        logger.info("Listening on port \(port)")
        try await serviceGroup.run()
    }
}
