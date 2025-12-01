import AppConfig
import ArgumentParser
import ContainerBuilder
import ContainerRegistry
import Crypto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import NIO
import NIOFileSystem
import Noora
import Subprocess
import WendyAgentGRPC
import WendyCLI

struct RunCommand: AsyncParsableCommand, Sendable {
    enum Error: Swift.Error, CustomStringConvertible {
        case failedToUploadLayers(Int)
        case noExecutableTarget
        case invalidExecutableTarget(String)
        case multipleExecutableTargets([String])
        case noManifestFound
        
        var description: String {
            switch self {
            case .failedToUploadLayers:
                return "Failed to upload"
            case .noExecutableTarget:
                return "No executable target found in package"
            case .invalidExecutableTarget(let name):
                return "No executable target named '\(name)' found in package"
            case .multipleExecutableTargets(let names):
                return "multiple executable targets available, but none specified: \(names.joined(separator: ", "))"
            case .noManifestFound:
                return "No manifest found in Docker image"
            }
        }
    }
    
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run Wendy projects."
    )
    
    @Flag(name: .long, help: "Attach a debugger to the container")
    var debug: Bool = false
    
    @Flag(name: .long, help: "Run the container in the background")
    var detach: Bool = false
    
    // Docker restart policy flags (mutually exclusive). Only applies to docker runtime.
    @Flag(name: .customLong("no-restart"), help: "Do not restart the container")
    var noRestart: Bool = false
    
    @Flag(name: .customLong("restart-unless-stopped"), help: "Restart unless stopped")
    var restartUnlessStoppedFlag: Bool = false
    
    @Option(
        name: .customLong("restart-on-failure"),
        help: "Restart on failure up to N times"
    )
    var restartOnFailureRetries: Int?
    
    @Argument(
        help: "The executable to run. Required when a package has multiple executable targets."
    )
    var executable: String?

    @OptionGroup
    var agentConnectionOptions: AgentConnectionOptions
    
    var swiftSDK: String { "6.2.1-RELEASE_wendyos_aarch64" }
    var swiftVersion: String { "+6.2.1" }
    var baseImage: String { "debian:bookworm-slim" }

    func run() async throws {
        let isSwiftPackage = FileManager.default.fileExists(atPath: "Package.swift")
        let directory = try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.currentDirectoryPath
        )

        for item in directory where item.lowercased().contains("dockerfile") {
            try await runContainerdBased()
            return
        }

        if isSwiftPackage {
            try await runSwiftContainerdBased()
        } else {
            Noora().error(
                "Directory is not a Swift Package, nor can it be built as a docker container"
            )
        }
    }

    func withTCPProxyServer<T: Sendable>(
        localHostname: String,
        localPort: Int,
        remoteHostname: String,
        remotePort: Int,
        _ withPort: @escaping @Sendable (NIOCore.SocketAddress?) async throws -> T
    ) async throws -> T {
        let server = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: numericCast(256))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .bind(
                host: localHostname,
                port: localPort,
                serverBackPressureStrategy: nil
            ) { channel in
                return channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init()
                    )
                }
            }

        func makeClient() async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
            try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .connect(host: remoteHostname, port: remotePort) { channel in
                    return channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: channel,
                            configuration: .init()
                        )
                    }
                }
        }

        let logger = Logger(label: "sh.wendy.cli.run.tcp-proxy-server")

        func handleClient(client: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws {
            do {
                try await client.executeThenClose { serverInbound, serverOutbound in
                    try await makeClient().executeThenClose { clientInbound, clientOutbound in
                        try await withThrowingTaskGroup { group in
                            group.addTask {
                                for try await buffer in serverInbound {
                                    try await clientOutbound.write(buffer)
                                }
                            }
                            group.addTask {
                                for try await buffer in clientInbound {
                                    try await serverOutbound.write(buffer)
                                }
                            }
                            try await group.waitForAll()
                        }
                    }
                }
            } catch is CancellationError {
                // Connection was cancelled (normal when buildx completes)
                logger.trace("Client connection cancelled")
            } catch {
                logger.error("Failed to handle client", metadata: ["error": .string("\(error)")])
            }
        }

        return try await server.executeThenClose { clients in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await client in clients {
                            group.addTask {
                                try await handleClient(client: client)
                            }
                        }
                    }
                }

                defer { group.cancelAll() }
                return try await withPort(server.channel.localAddress)
            }
        }
    }

    func runContainerdBased() async throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let name = url.lastPathComponent.lowercased()

        let docker = DockerCLI()

        let title = TerminalText(stringLiteral: "Which device do you want to run this app on?")
        let endpoint = try await agentConnectionOptions.read(title: title)
        try await _withAgentGRPCClient(
            endpoint,
            title: title
        ) { [name] client, endpoint in
            // Bind to all interfaces for Docker Desktop compatibility
            try await withTCPProxyServer(
                localHostname: "0.0.0.0",
                localPort: 50053,
                remoteHostname: endpoint.host,
                remotePort: 5000
            ) { proxyAddress in
                let port = proxyAddress?.port ?? 50053
                let builderName = docker.builderName(forPort: port)

                if try await !docker.hasBuildxBuilder(builderName: builderName) {
                    // Create buildx builder with insecure registry support
                    try await Noora().progressStep(
                        message: "Setting up builder",
                        successMessage: "Builder ready",
                        errorMessage: "Failed to create builder",
                        showSpinner: true
                    ) { _ in
                        try await docker.createBuildxBuilder(port: port)
                    }
                }

                // Build and push in a single operation for better performance
                try await Noora().progressStep(
                    message: "Building and uploading container",
                    successMessage: "Container built and uploaded successfully!",
                    errorMessage: "Failed to build and upload container",
                    showSpinner: true
                ) { _ in
                    try await docker.buildxAndPush(name: name, port: port, builder: builderName)
                }
            }

            try await Noora().progressStep(
                message: "Preparing app",
                successMessage: "App ready to start",
                errorMessage: "Failed to prepare app",
                showSpinner: true
            ) { _ in
                try await createContainerdContainer(
                    appName: name,
                    client: client
                )
            }

            try await startContainerdContainer(
                imageName: name,
                client: client
            )
        }
    }

    struct ContainerdLayer: Sendable {
        enum Source: @unchecked Sendable {
            case path(URL)
            case stream(any AsyncSequence<ArraySlice<UInt8>, any Swift.Error>)
        }

        let source: Source
        let digest: String
        let diffID: String
        let size: Int64
        let gzip: Bool
        let logger = Logger(label: "sh.wendy.cli.run.containerd.layer.stream")
        
        func withData<T: Sendable>(_ withData: @escaping @Sendable (Data) async throws -> T) async throws -> T {
            switch source {
            case .path(let url):
                logger.debug("Reading layer from path", metadata: ["path": .string(url.path())])
                return try await FileSystem.shared.withFileHandle(
                    forReadingAt: FilePath(url.path())
                ) { fileHandle in
                    let data = Data(buffer: try await fileHandle.readToEnd(maximumSizeAllowed: .unlimited))
                    return try await withData(data)
                }
            case .stream(let asyncSequence):
                var data = Data()
                for try await chunk in asyncSequence {
                    data.append(contentsOf: chunk)
                }
                return try await withData(data)
            }
        }

        func withStream(_ write: (ArraySlice<UInt8>) async throws -> Void) async throws {
            switch source {
            case .path(let url):
                logger.debug("Reading layer from path", metadata: ["path": .string(url.path())])
                try await FileSystem.shared.withFileHandle(
                    forReadingAt: FilePath(url.path())
                ) { fileHandle in
                    logger.debug("Reading layer from file handle")
                    for try await chunk in fileHandle.readChunks() {
                        logger.trace(
                            "Reading layer chunk",
                            metadata: ["size": .string("\(chunk.readableBytesView.count) bytes")]
                        )
                        try await write(Array(buffer: chunk)[...])
                    }
                }
            case .stream(let asyncSequence):
                for try await chunk in asyncSequence {
                    try await write(chunk)
                }
            }
        }
    }
    

    struct LayerSource: Codable, Sendable {
        let mediaType: String
        let size: Int64
        let digest: String

        enum CodingKeys: String, CodingKey {
            case mediaType = "mediaType"
            case size = "size"
            case digest = "digest"
        }
    }

    struct ContainerConfig: Codable, Sendable {
        let cmd: [String]?
        let env: [String]?
        let workingDir: String?
        let user: String?
        let exposedPorts: [String: [String: String]]?
        let labels: [String: String]?

        enum CodingKeys: String, CodingKey {
            case cmd = "Cmd"
            case env = "Env"
            case workingDir = "WorkingDir"
            case user = "User"
            case exposedPorts = "ExposedPorts"
            case labels = "Labels"
        }
    }

    struct ImageConfig: Codable, Sendable {
        let architecture: String
        let os: String
        let config: ContainerConfig
        let rootfs: RootFS

        enum CodingKeys: String, CodingKey {
            case architecture = "architecture"
            case os = "os"
            case config = "config"
            case rootfs = "rootfs"
        }
    }

    struct RootFS: Codable, Sendable {
        let type: String
        let diffIds: [String]

        enum CodingKeys: String, CodingKey {
            case type = "type"
            case diffIds = "diff_ids"
        }
    }

    func uploadAndRunContainerdContainer(
        layers: [ContainerdLayer],
        imageName: String,
        config: ImageConfig,
        logger: Logger
    ) async throws {
        if layers.isEmpty {
            logger.warning("No layers to run")
            return
        }

        try await withAgentGRPCClientAndEndpoint(
            agentConnectionOptions,
            title: "Which device do you want to run this app on?"
        ) { client, endpoint in
            // Upload layers in parallel
            // This is useful because a stream can only handle one chunk at a time
            // But the networking latency might be high enough over WiFi that we can
            // satisfy the disk more by making more streams. Many streams share a TCP connection
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                actor LayersUploaded {
                    var status = Status()
                    
                    struct Status: Sendable {
                        var layersUploading = 0
                        var layersUploaded = 0
                        var layersFailedUploaded = 0
                        var expectedBytes: Int64 = 0
                        var uploadedBytes: Int64 = 0
                        var progress: Double {
                            return Double(uploadedBytes) / Double(expectedBytes)
                        }
                        
                        var message: String {
                            if layersFailedUploaded > 0 {
                                return "Layers uploading \(layersUploaded)/\(layersUploading) (failed: \(layersFailedUploaded))"
                            } else {
                                return "Layers uploading \(layersUploaded)/\(layersUploading)"
                            }
                        }
                    }
                    nonisolated let (statusChange, continuation) = AsyncStream<Status>.makeStream(
                        bufferingPolicy: .bufferingNewest(1)
                    )
                    
                    func incrementUploading(_ bytes: Int64) {
                        status.layersUploading += 1
                        status.expectedBytes += bytes
                        continuation.yield(status)
                    }
                    
                    func uploaded(_ bytes: Int64) {
                        status.uploadedBytes += bytes
                        continuation.yield(status)
                        checkFinished()
                    }
                    
                    func incrementUploaded() {
                        status.layersUploaded += 1
                        continuation.yield(status)
                        checkFinished()
                    }
                    
                    func incrementFailedUploaded(error: any Swift.Error) {
                        status.layersFailedUploaded += 1
                        status.layersUploading -= 1
                        continuation.yield(status)
                        checkFinished()
                    }
                    
                    private func checkFinished() {
                        if status.layersUploaded == status.layersUploading {
                            finish()
                        }
                    }
                    
                    nonisolated func finish() {
                        continuation.finish()
                    }
                    
                    deinit {
                        finish()
                    }
                }
                
                let layersUploaded = LayersUploaded()
                let repository = ImageReference(
                    registry: "\(endpoint.host):5000",
                    repository: imageName,
                    reference: "latest"
                )
                let registry = try await RegistryClient(
                    registry: "\(endpoint.host):5000",
                    insecure: true
                )
                for layer in layers {
                    await layersUploaded.incrementUploading(layer.size)
                    taskGroup.addTask {
                        // Upload layers that have changed or are new
                        logger.debug(
                            "Uploading layer to agent",
                            metadata: ["digest": .string(layer.digest)]
                        )
                        do {
                            if try await registry.blobExists(repository: repository.repository, digest: layer.digest) {
                                logger.debug(
                                    "Layer already exists in registry",
                                    metadata: ["digest": .string(layer.digest)]
                                )
                                await layersUploaded.incrementUploaded()
                                return
                            }
                            
                            let uploaded = try await layer.withData { data in
                                return try await registry.putBlob(
                                    repository: repository.repository,
                                    data: data
                                )
                            }
                            guard uploaded.digest == layer.digest else {
                                throw RegistryClientError.digestMismatch(expected: layer.digest, registry: uploaded.digest)
                            }
                            logger.debug(
                                "Uploaded layer successfully",
                                metadata: ["digest": .string(layer.digest)]
                            )
                            await layersUploaded.incrementUploaded()
                        } catch {
                            logger.error(
                                "Failed to upload layer",
                                metadata: [
                                    "digest": .string(layer.digest),
                                    "error": .string("\(error)"),
                                ]
                            )
                            
                            logger.error(
                                "Failed to upload layer",
                                metadata: ["error": .string("\(error)")]
                            )
                            await layersUploaded.incrementFailedUploaded(error: error)
                        }
                    }
                }
                
                try await Noora().progressBarStep(
                    message: "Uploading layers to agent"
                ) { progress in
                    for await status in layersUploaded.statusChange {
                        progress(status.progress)
                    }
                    
                    let errors = await layersUploaded.status.layersFailedUploaded
                    if errors > 0 {
                        throw Error.failedToUploadLayers(errors)
                    }
                }
                
                layersUploaded.finish()
                
                try await taskGroup.waitForAll()

                let configDescriptor = try await registry.putBlob(
                    repository: repository.repository,
                    mediaType: "application/vnd.oci.image.config.v1+json",
                    data: config
                )

                let manifest = ImageManifest(
                    schemaVersion: 2,
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    config: ContentDescriptor(
                        mediaType: "application/vnd.oci.image.config.v1+json",
                        digest: configDescriptor.digest,
                        size: configDescriptor.size
                    ),
                    layers: layers.map { layer in
                        return ContentDescriptor(
                            mediaType: layer.gzip ? "application/vnd.oci.image.layer.v1.tar+gzip" : "application/vnd.oci.image.layer.v1.tar",
                            digest: layer.digest,
                            size: layer.size
                        )
                    }
                )

                _ = try await registry.putManifest(
                    repository: repository.repository,
                    reference: "latest",
                    manifest: manifest
                )
                let index = ImageIndex(
                    schemaVersion: 2,
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    manifests: [
                        ContentDescriptor(
                            mediaType: "application/vnd.oci.image.manifest.v1+json",
                            digest: manifest.digest,
                            size: manifest.size,
                            platform: .init(architecture: config.architecture, os: config.os)
                        )
                    ]
                )
                _ = try await registry.putIndex(repository: repository.repository, reference: "latest", index: index)
            }
            
            try await Noora().progressStep(
                message: "Preparing app",
                successMessage: "App ready to start",
                errorMessage: "Failed to prepare app",
                showSpinner: true
            ) { _ in
                try await createContainerdContainer(
                    appName: imageName,
                    client: client
                )
            }
            
            try await startContainerdContainer(imageName: imageName, client: client)
        }
    }

    func createContainerdContainer(
        appName: String,
        client: GRPCClient<HTTP2ClientTransport.Posix>
    ) async throws {
        let logger = Logger(label: "sh.wendy.cli.run.containerd.create")
        let agentContainers = Wendy_Agent_Services_V1_WendyContainerService.Client(
            wrapping: client
        )

        let appConfigData = try await readAppConfigData(logger: logger)
        _ = try await agentContainers.createContainer(
            request: .init(
                message: .with {
                    // The image is pushed to the device's local registry as just "appName"
                    // The host.docker.internal:port prefix is only for routing during push
                    $0.imageName = "\(appName):latest"
                    $0.appName = appName
                    $0.appConfig = appConfigData
                    if noRestart {
                        $0.restartPolicy = .with {
                            $0.mode = .no
                        }
                    } else if let retries = restartOnFailureRetries {
                        $0.restartPolicy = .with {
                            $0.mode = .onFailure
                            $0.onFailureMaxRetries = Int32(retries)
                        }
                    } else if restartUnlessStoppedFlag {
                        $0.restartPolicy = .with {
                            $0.mode = .unlessStopped
                        }
                    } else {
                        $0.restartPolicy = .with {
                            $0.mode = .default
                        }
                    }
                }
            )
        )
    }

    func startContainerdContainer(
        imageName: String,
        client: GRPCClient<HTTP2ClientTransport.Posix>
    ) async throws {
        let logger = Logger(label: "sh.wendy.cli.run.containerd.start")
        let agentContainers = Wendy_Agent_Services_V1_WendyContainerService.Client(
            wrapping: client
        )

        _ = try await agentContainers.startContainer(
            request: .init(
                message: .with {
                    $0.appName = imageName
                }
            )
        ) { response in
            for try await message in response.messages {
                switch message.responseType {
                case .started:
                    if debug {
                        Noora().success("Started container with debug port 4242")
                    } else {
                        Noora().success("Started app")
                    }

                    if detach {
                        return
                    }
                case .stdoutOutput(let stdoutOutput):
                    stdoutOutput.data.withUnsafeBytes { data in
                        _ = write(STDOUT_FILENO, data.baseAddress!, data.count)
                    }
                case .stderrOutput(let stderrOutput):
                    stderrOutput.data.withUnsafeBytes { data in
                        _ = write(STDERR_FILENO, data.baseAddress!, data.count)
                    }
                default:
                    logger.warning("Unknown message received from agent")
                }
            }
        }
    }

    func buildDockerBased(name: String) async throws {
        let logger = Logger(label: "sh.wendy.cli.run.docker.container.build")
        let docker = DockerCLI()
        try await docker.build(name: name)
        logger.debug("Container built successfully!")
    }

    func addSwiftPMResources(
        at buildDir: URL,
        to spec: inout ContainerImageSpec
    ) async throws {
        let logger = Logger(label: "sh.wendy.cli.run.swiftpm-resources")
        let items = try FileManager.default.contentsOfDirectory(
            at: buildDir,
            includingPropertiesForKeys: nil
        )

        var files = [ContainerImageSpec.Layer.File]()

        for item in items where item.lastPathComponent.hasSuffix(".resources") {
            logger.trace(
                "Found resources in build dir",
                metadata: [
                    "path": "\(item.path())"
                ]
            )
            files.append(
                .init(
                    source: item,
                    destination: "/bin/\(item.lastPathComponent)",
                    permissions: 0o700
                )
            )
        }

        if !files.isEmpty {
            logger.debug(
                "Appending resources layer to spec",
                metadata: [
                    "files": .stringConvertible(files.count)
                ]
            )
            spec.layers.append(
                ContainerImageSpec.Layer(files: files)
            )
        }
    }

    func runSwiftContainerdBased() async throws {
        let logger = Logger(label: "sh.wendy.cli.run.containerd")

        let swiftPM = SwiftPM()
        let package = try await swiftPM.dumpPackage(
            .scratchPath(".wendy-build")
        )

        // Get all executable targets
        let executableTargets = package.targets.filter { $0.type == "executable" }

        // Use specified executable or handle multiple executable targets
        let executableTarget: SwiftPM.Package.Target
        if let executableName = executable {
            guard let target = executableTargets.first(where: { $0.name == executableName }) else {
                throw Error.invalidExecutableTarget(executableName)
            }
            executableTarget = target
        } else {
            // If no executable specified, ensure there's only one executable target
            if executableTargets.isEmpty {
                throw Error.noExecutableTarget
            } else if executableTargets.count > 1 {
                throw Error.multipleExecutableTargets(executableTargets.map(\.name))
            } else {
                executableTarget = executableTargets[0]
            }
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let (imageName, container) = try await Noora().progressStep(
            message: "Building container",
            successMessage: "Container built successfully!",
            errorMessage: "Failed to build container",
            showSpinner: true
        ) { progress in
            progress("Building Swift app")
            try await swiftPM.build(
                .product(executableTarget.name),
                .swiftSDK(swiftSDK),
                .configuration(debug ? "debug" : "release"),
                .scratchPath(".wendy-build"),
                .staticSwiftStdlib,
                .xLinker("-s")
            )

            progress("Building container with base image \(baseImage)")
            let binPath = try await swiftPM.buildWithOutput(
                .showBinPath,
                .product(executableTarget.name),
                .swiftSDK(swiftSDK),
                .configuration(debug ? "debug" : "release"),
                .quiet,
                .scratchPath(".wendy-build"),
                .staticSwiftStdlib
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let buildDir = URL(fileURLWithPath: binPath)
            let executable = buildDir.appendingPathComponent(executableTarget.name)

            logger.debug("Building container with base image \(baseImage)")
            progress("Preparing base image")
            let imageName = executableTarget.name.lowercased()

            // Use the debian:bookworm-slim base image instead of a blank image
            var imageSpec = try await ContainerImageSpec.withBaseImage(
                baseImage: baseImage,
                executable: executable
            )
            progress("Adding Swift PM resources")
            try await addSwiftPMResources(at: buildDir, to: &imageSpec)

            progress("Adding debugger executable")
            if debug {
                // Include the ds2 executable in the container image.
                let ds2URL: URL
                if let url = Bundle.module.url(
                    forResource: "ds2-124963fd-static-linux-arm64",
                    withExtension: nil
                ) {
                    ds2URL = url
                } else {
                    let url = URL(fileURLWithPath: CommandLine.arguments[0])
                        .deletingLastPathComponent()
                        .appending(path: "wendy-agent_wendy.bundle")
                        .appending(path: "Contents")
                        .appending(path: "Resources")
                        .appending(path: "Resources")
                        .appending(component: "ds2-124963fd-static-linux-arm64")

                    guard FileManager.default.fileExists(atPath: url.path()) else {
                        fatalError("Could not find ds2 executable in bundle resources")
                    }

                    ds2URL = url
                }

                let ds2Files = [
                    ContainerImageSpec.Layer.File(
                        source: ds2URL,
                        destination: "/bin/ds2",
                        permissions: 0o755
                    )
                ]
                let ds2Layer = ContainerImageSpec.Layer(files: ds2Files)
                imageSpec.layers.append(ds2Layer)
            }

            progress("Building final container image")
            let container = try await buildDockerContainer(
                image: imageSpec,
                imageName: imageName,
                tempDir: tempDir
            )
            return (imageName, container)
        }

        let cmd: [String]
        if debug {
            cmd = [
                "ds2",
                "gdbserver",
                "0.0.0.0:4242",
                "/bin/\(imageName)",
            ]
        } else {
            // Use the command from the config, or fallback to the image name
            cmd = ["/bin/\(imageName)"]
        }
        // Create a default config for Swift-based containers
        let defaultConfig = ImageConfig(
            architecture: "arm64",
            os: "linux",
            config: ContainerConfig(
                cmd: cmd,
                env: nil,
                workingDir: "/",
                user: nil,
                exposedPorts: nil,
                labels: nil
            ),
            rootfs: RootFS(
                type: "layers",
                diffIds: container.layers.map(\.diffID)
            )
        )

        try await uploadAndRunContainerdContainer(
            layers: container.layers.map { layer in
                ContainerdLayer(
                    source: .path(layer.path),
                    digest: layer.digest,
                    diffID: layer.diffID,
                    size: layer.size,
                    gzip: layer.gzip
                )
            },
            imageName: imageName,
            config: defaultConfig,
            logger: logger
        )
    }

    private func readAppConfigData(logger: Logger) async throws -> Data {
        do {
            let appConfigData = try Data(contentsOf: URL(fileURLWithPath: "./wendy.json"))
            // Validate data
            _ = try JSONDecoder().decode(AppConfig.self, from: appConfigData)
            return appConfigData
        } catch {
            logger.debug("Failed to decode app config", metadata: ["error": .string("\(error)")])
            Noora().info("No valid wendy.json was found. Using default settings.")
            return Data()
        }
    }

    private func writeHTTPBodyToFile(
        body: any AsyncSequence<ArraySlice<UInt8>, any Swift.Error>,
        to url: URL
    ) async throws {
        try await FileSystem.shared.withFileHandle(
            forWritingAt: FilePath(url.path()),
            options: .newFile(replaceExisting: true)
        ) { fileHandle in
            var writer = fileHandle.bufferedWriter()
            for try await chunk in body {
                try await writer.write(contentsOf: chunk)
            }
        }
    }

    private func extractTar(from sourceURL: URL, to destinationURL: URL) async throws {
        _ = try await Subprocess.run(
            .name("tar"),
            arguments: Subprocess.Arguments([
                "-xf", sourceURL.path, "-C", destinationURL.path,
            ]),
            output: .discarded
        )
    }

    private func calculateDigest(for fileURL: URL) async throws -> String {
        return try await FileSystem.shared.withFileHandle(
            forReadingAt: FilePath(fileURL.path)
        ) { fileHandle in
            var sha = SHA256()
            for try await chunk in fileHandle.readChunks() {
                sha.update(data: chunk.readableBytesView)
            }
            let hash = sha.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
            return "sha256:\(hash)"
        }
    }
}
