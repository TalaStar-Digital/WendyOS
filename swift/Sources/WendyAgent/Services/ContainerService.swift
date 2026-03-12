import CryptoKit
import Foundation
import GRPCCore
import Logging
import OpenTelemetryGRPC
import WendyAgentGRPC

actor ContainerService: Wendy_Agent_Services_V1_WendyContainerService.ServiceProtocol {
    private let appsDir: String
    private let broadcaster: TelemetryBroadcaster
    private let executablePath: String
    private let logger = Logger(label: "sh.wendy.agent.container")
    private var runningProcesses: [String: Foundation.Process] = [:]
    private let sandboxProfilePath: String?

    /// Maps app name → (appDir, binaryName) for apps uploaded via WriteLayer.
    private var appDirs: [String: (dir: String, binaryName: String)] = [:]

    init(broadcaster: TelemetryBroadcaster, executablePath: String, sandboxProfilePath: String? = nil, appsDir: String? = nil) {
        self.broadcaster = broadcaster
        self.executablePath = executablePath
        self.sandboxProfilePath = sandboxProfilePath

        let dir = appsDir ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/Application Support/wendy-agent/apps"
        }()
        self.appsDir = dir

        // Ensure the apps directory exists.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    // MARK: - Implemented

    func createContainer(
        request: ServerRequest<Wendy_Agent_Services_V1_CreateContainerRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_CreateContainerResponse> {
        let appName = request.message.appName
        let binaryName = request.message.imageName
        logger.info("CreateContainer called", metadata: ["app_name": "\(appName)", "image_name": "\(binaryName)"])

        // If imageName is set and a matching binary was uploaded, register the app directory.
        if !binaryName.isEmpty {
            let appDir = "\(appsDir)/\(appName)"
            let binaryPath = "\(appDir)/\(binaryName)"
            guard FileManager.default.fileExists(atPath: binaryPath) else {
                throw RPCError(code: .notFound, message: "Binary not found at \(binaryPath)")
            }
            appDirs[appName] = (dir: appDir, binaryName: binaryName)
            logger.info("Registered app directory", metadata: ["app_name": "\(appName)", "binary": "\(binaryPath)"])
        }

        return ServerResponse(message: Wendy_Agent_Services_V1_CreateContainerResponse())
    }

    func startContainer(
        request: ServerRequest<Wendy_Agent_Services_V1_StartContainerRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_RunContainerLayersResponse> {
        let appName = request.message.appName
        logger.info("StartContainer called", metadata: ["app_name": "\(appName)"])

        // Stop any existing process with the same name.
        if let existing = runningProcesses[appName] {
            if existing.isRunning {
                existing.terminate()
                existing.waitUntilExit()
            }
            runningProcesses.removeValue(forKey: appName)
        }

        // Resolve binary path: prefer uploaded app, fall back to --appPath.
        let binaryPath: String
        let profilePath: String?
        if let entry = appDirs[appName] {
            binaryPath = "\(entry.dir)/\(entry.binaryName)"
            let candidateProfile = "\(entry.dir)/sandbox.sb"
            profilePath = FileManager.default.fileExists(atPath: candidateProfile) ? candidateProfile : nil
        } else {
            binaryPath = executablePath
            profilePath = sandboxProfilePath
        }

        let process = Foundation.Process()
        if let profilePath {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-f", profilePath, binaryPath]
            logger.info("Launching \(binaryPath) sandboxed with profile \(profilePath)")
        } else {
            process.executableURL = URL(fileURLWithPath: binaryPath)
            logger.info("Launching \(binaryPath) (not sandboxed)")
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try! process.run()
        runningProcesses[appName] = process
        logger.info("Process started", metadata: ["app_name": "\(appName)", "pid": "\(process.processIdentifier)"])

        // Capture values for the sendable closure.
        let broadcaster = self.broadcaster

        return StreamingServerResponse { writer in
            // Send "started" message.
            var started = Wendy_Agent_Services_V1_RunContainerLayersResponse()
            started.responseType = .started(Wendy_Agent_Services_V1_RunContainerLayersResponse.Started())
            try await writer.write(started)

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Stream stdout.
                group.addTask {
                    let handle = stdoutPipe.fileHandleForReading
                    for try await data in handle.bytes(for: appName) {
                        var msg = Wendy_Agent_Services_V1_RunContainerLayersResponse()
                        msg.responseType = .stdoutOutput(.with { $0.data = data })
                        try await writer.write(msg)

                        await Self.broadcastLog(
                            broadcaster: broadcaster,
                            appName: appName,
                            text: String(decoding: data, as: UTF8.self),
                            stream: "stdout",
                            severity: .info
                        )
                    }
                }

                // Stream stderr.
                group.addTask {
                    let handle = stderrPipe.fileHandleForReading
                    for try await data in handle.bytes(for: appName) {
                        var msg = Wendy_Agent_Services_V1_RunContainerLayersResponse()
                        msg.responseType = .stderrOutput(.with { $0.data = data })
                        try await writer.write(msg)

                        await Self.broadcastLog(
                            broadcaster: broadcaster,
                            appName: appName,
                            text: String(decoding: data, as: UTF8.self),
                            stream: "stderr",
                            severity: .warn
                        )
                    }
                }

                // Wait for process exit.
                group.addTask {
                    process.waitUntilExit()
                }

                try await group.waitForAll()
            }

            return Metadata()
        }
    }

    func stopContainer(
        request: ServerRequest<Wendy_Agent_Services_V1_StopContainerRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_StopContainerResponse> {
        let appName = request.message.appName
        logger.info("StopContainer called", metadata: ["app_name": "\(appName)"])

        if let process = runningProcesses.removeValue(forKey: appName) {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            logger.info("Process stopped", metadata: ["app_name": "\(appName)"])
        } else {
            logger.warning("No running process found", metadata: ["app_name": "\(appName)"])
        }

        return ServerResponse(message: Wendy_Agent_Services_V1_StopContainerResponse())
    }

    func deleteContainer(
        request: ServerRequest<Wendy_Agent_Services_V1_DeleteContainerRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_DeleteContainerResponse> {
        let appName = request.message.appName
        logger.info("DeleteContainer called", metadata: ["app_name": "\(appName)"])

        // Stop if running, then remove.
        if let process = runningProcesses.removeValue(forKey: appName) {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        return ServerResponse(message: Wendy_Agent_Services_V1_DeleteContainerResponse())
    }

    func listContainers(
        request: ServerRequest<Wendy_Agent_Services_V1_ListContainersRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_ListContainersResponse> {
        let processes = runningProcesses
        return StreamingServerResponse { writer in
            for (appName, process) in processes {
                var container = AppContainer()
                container.appName = appName
                container.runningState = process.isRunning ? .running : .stopped

                var response = Wendy_Agent_Services_V1_ListContainersResponse()
                response.container = container
                try await writer.write(response)
            }

            return Metadata()
        }
    }

    // MARK: - Unimplemented

    func listLayers(
        request: ServerRequest<Wendy_Agent_Services_V1_ListLayersRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_LayerHeader> {
        throw RPCError(code: .unimplemented, message: "ListLayers is not implemented")
    }

    func writeLayer(
        request: StreamingServerRequest<Wendy_Agent_Services_V1_WriteLayerRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_WriteLayerResponse> {
        // Digest format: "<appName>:<filename>:sha256:<hash>"
        var appName = ""
        var filename = ""
        var expectedHash = ""
        var accumulated = Data()

        for try await message in request.messages {
            // Parse digest from the first message that carries it.
            if !message.digest.isEmpty && appName.isEmpty {
                let parts = message.digest.split(separator: ":", maxSplits: 3).map(String.init)
                guard parts.count == 4, parts[2] == "sha256" else {
                    throw RPCError(code: .invalidArgument, message: "Invalid digest format: expected <appName>:<filename>:sha256:<hash>")
                }
                appName = parts[0]
                filename = parts[1]
                expectedHash = parts[3]
                logger.info("WriteLayer started", metadata: ["app_name": "\(appName)", "filename": "\(filename)"])
            }
            if !message.data.isEmpty {
                accumulated.append(message.data)
            }
        }

        guard !appName.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "No digest received in WriteLayer stream")
        }

        // Verify SHA256.
        let computedHash = SHA256.hash(data: accumulated)
            .map { String(format: "%02x", $0) }
            .joined()
        guard computedHash == expectedHash else {
            throw RPCError(
                code: .dataLoss,
                message: "SHA256 mismatch: expected \(expectedHash), got \(computedHash)"
            )
        }

        // Write to disk.
        let appDir = "\(appsDir)/\(appName)"
        try FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        let filePath = "\(appDir)/\(filename)"
        try accumulated.write(to: URL(fileURLWithPath: filePath))

        // Set executable permission if this is not the sandbox profile.
        if filename != "sandbox.sb" {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filePath)
        }

        logger.info("WriteLayer completed", metadata: [
            "app_name": "\(appName)",
            "filename": "\(filename)",
            "size": "\(accumulated.count)",
        ])

        return StreamingServerResponse { _ in
            return Metadata()
        }
    }

    func createContainerWithProgress(
        request: ServerRequest<Wendy_Agent_Services_V1_CreateContainerRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_CreateContainerProgressResponse> {
        throw RPCError(code: .unimplemented, message: "CreateContainerWithProgress is not implemented")
    }

    func runContainer(
        request: ServerRequest<Wendy_Agent_Services_V1_RunContainerLayersRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_RunContainerLayersResponse> {
        throw RPCError(code: .unimplemented, message: "RunContainer is not implemented")
    }

    // MARK: - Helpers

    private static func broadcastLog(
        broadcaster: TelemetryBroadcaster,
        appName: String,
        text: String,
        stream: String,
        severity: Opentelemetry_Proto_Logs_V1_SeverityNumber
    ) async {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)

        var logRecord = Opentelemetry_Proto_Logs_V1_LogRecord()
        logRecord.timeUnixNano = timestamp
        logRecord.observedTimeUnixNano = timestamp
        logRecord.severityNumber = severity
        logRecord.severityText = severity == .info ? "INFO" : "WARN"
        logRecord.body = .with { $0.stringValue = text }
        logRecord.attributes.append(.with {
            $0.key = "stream"
            $0.value = .with { $0.stringValue = stream }
        })

        var scopeLogs = Opentelemetry_Proto_Logs_V1_ScopeLogs()
        scopeLogs.logRecords = [logRecord]

        var resourceLogs = Opentelemetry_Proto_Logs_V1_ResourceLogs()
        resourceLogs.scopeLogs = [scopeLogs]
        resourceLogs.resource.attributes.append(.with {
            $0.key = "service.name"
            $0.value = .with { $0.stringValue = appName }
        })
        resourceLogs.resource.attributes.append(.with {
            $0.key = "wendy.app.name"
            $0.value = .with { $0.stringValue = appName }
        })

        await broadcaster.broadcastLogs(
            Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest.with {
                $0.resourceLogs = [resourceLogs]
            }
        )
    }
}

// MARK: - FileHandle async bytes helper

extension FileHandle {
    /// Read available data from the file handle as an async sequence of chunks.
    func bytes(for label: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }
        }
    }
}
