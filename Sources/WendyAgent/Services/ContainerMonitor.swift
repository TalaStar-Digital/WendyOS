import ContainerdGRPC
import Foundation
import Logging
import NIO
import Subprocess

/// Monitor service that watches containers and enforces restart policies for containerd apps
actor ContainerMonitor {
    private let logger = Logger(label: "ContainerMonitor")
    private var monitoring = false
    private var monitorTask: Task<Void, Never>?

    /// Container restart state tracking
    private struct ContainerState {
        let appName: String
        let imageName: String
        var failureCount: Int = 0
        var lastRestartTime: Date?
        var restartPolicy: RestartPolicy
        var explicitlyStopped: Bool = false
    }

    /// Parsed restart policy from labels
    enum RestartPolicy {
        case no
        case unlessStopped
        case onFailure(maxRetries: Int)
        case always

        init(from labelValue: String) {
            switch labelValue {
            case "no":
                self = .no
            case "unless-stopped":
                self = .unlessStopped
            case "always":
                self = .always
            default:
                if labelValue.hasPrefix("on-failure:") {
                    let parts = labelValue.split(separator: ":")
                    if parts.count == 2, let maxRetries = Int(parts[1]) {
                        self = .onFailure(maxRetries: maxRetries)
                    } else {
                        self = .onFailure(maxRetries: 5)  // Default to 5 retries
                    }
                } else {
                    self = .no  // Default policy
                }
            }
        }
    }

    private var containerStates: [String: ContainerState] = [:]

    /// Start monitoring containers
    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true

        monitorTask = Task {
            logger.info("Starting container monitor service")

            // Small delay to let containerd fully start after boot
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            while monitoring {
                do {
                    try await checkContainers()
                    try await Task.sleep(nanoseconds: 15_000_000_000)  // Check every 15 seconds
                } catch {
                    logger.error("Error in container monitor", metadata: ["error": "\(error)"])
                    try? await Task.sleep(nanoseconds: 30_000_000_000)  // Wait 30 seconds on error
                }
            }

            logger.info("Container monitor service stopped")
        }
    }

    /// Stop monitoring containers
    func stopMonitoring() {
        monitoring = false
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Mark a container as explicitly stopped (won't be auto-restarted)
    func markContainerStopped(_ appName: String) {
        if containerStates[appName] != nil {
            containerStates[appName]?.explicitlyStopped = true
            logger.info("Marked container as explicitly stopped", metadata: ["container": "\(appName)"])
        }
    }

    /// Mark a container as running (can be auto-restarted again)
    func markContainerStarted(_ appName: String) {
        if containerStates[appName] != nil {
            containerStates[appName]?.explicitlyStopped = false
            containerStates[appName]?.failureCount = 0
            logger.info("Marked container as started", metadata: ["container": "\(appName)"])
        }
    }

    /// Check container status and restart if needed
    private func checkContainers() async throws {
        // Use containerd API to get containers and their labels
        let (containers, tasks) = try await Containerd.withClient { client in
            let tasks = try await client.listTasks()
            let containers = try await client.listContainers()
            return (containers, tasks)
        }

        var wendyContainers = 0
        for container in containers {
            // Check if this is a Wendy-managed container
            guard container.labels["sh.wendy/app.version"] != nil else {
                // skip non-Wendy containers
                continue
            }

            wendyContainers += 1
            await checkAndRestartContainer(
                container: container,
                tasks: tasks
            )
        }

        // Clean up state for containers that no longer exist
        let existingContainerNames = Set(containers.map(\.id))
        containerStates = containerStates.filter { existingContainerNames.contains($0.key) }
    }

    /// Check individual container and restart if needed
    private func checkAndRestartContainer(
        container: Containerd_Services_Containers_V1_Container,
        tasks: [Containerd_V1_Types_Process]
    ) async {
        let appName = container.id
        let restartPolicyLabel = container.labels["containerd.io/restart.policy"] ?? "unless-stopped"
        let restartPolicy = RestartPolicy(from: restartPolicyLabel)

        // Find the task (running state) for this container
        let task = tasks.first(where: { $0.id == appName })
        let isRunning = task?.status == .running

        // Update or create container state
        if containerStates[appName] == nil {
            containerStates[appName] = ContainerState(
                appName: appName,
                imageName: container.image,
                restartPolicy: restartPolicy
            )
            logger.debug("Created new container state for \(appName)")
        } else {
            containerStates[appName]?.restartPolicy = restartPolicy
        }

        guard var state = containerStates[appName] else { return }

        // Check if container should be restarted
        let shouldRestart = shouldRestartContainer(
            isRunning: isRunning,
            state: state,
            exitCode: Int(task?.exitStatus ?? 0)
        )

        if shouldRestart {
            logger.debug(
                "Restarting container",
                metadata: [
                    "container": "\(appName)",
                    "failure-count": "\(state.failureCount)"
                ]
            )

            do {
                // Utilize nerdctl to restart the container
                _ = try await runNerdctl(["start", appName])

                state.lastRestartTime = Date()
                state.failureCount += 1
                containerStates[appName] = state

                logger.debug(
                    "Container restarted successfully",
                    metadata: ["container": "\(appName)"]
                )
            } catch {
                logger.error(
                    "Failed to restart container",
                    metadata: [
                        "container": "\(appName)",
                        "error": "\(error)"
                    ]
                )
            }
        }
    }

    /// Determine if a container should be restarted based on its state and policy
    private func shouldRestartContainer(
        isRunning: Bool,
        state: ContainerState,
        exitCode: Int
    ) -> Bool {
        // Don't restart if explicitly stopped by user
        if state.explicitlyStopped {
            return false
        }

        // Container is running fine
        if isRunning {
            return false
        }

        // Container is stopped, check restart policy
        switch state.restartPolicy {
        case .no:
            return false

        case .always, .unlessStopped:
            // Always restart unless explicitly stopped
            return true

        case .onFailure(let maxRetries):
            // Only restart on non-zero exit code, up to max retries
            if exitCode != 0 && state.failureCount < maxRetries {
                return true
            }
            return false
        }
    }

    /// Run nerdctl command for container operations
    private func runNerdctl(_ args: [String]) async throws -> String {
        let fullArgs = ["--namespace", "default"] + args
        logger.info("Running nerdctl command", metadata: ["args": "\(fullArgs.joined(separator: " "))"])

        do {
            let result = try await Subprocess.run(
                .name("/usr/local/bin/nerdctl"),
                arguments: Subprocess.Arguments(fullArgs),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

            if let stderr = result.standardError, !stderr.isEmpty {
                logger.warning("nerdctl stderr output", metadata: ["stderr": "\(stderr)"])
            }

            let stdout = result.standardOutput ?? ""
            return stdout
        } catch {
            logger.error("Failed to run nerdctl", metadata: [
                "command": "nerdctl \(fullArgs.joined(separator: " "))",
                "error": "\(error)"
            ])
            throw error
        }
    }
}

// Singleton instance
let containerMonitor = ContainerMonitor()