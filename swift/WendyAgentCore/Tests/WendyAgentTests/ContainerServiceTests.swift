import Darwin
import Foundation
import GRPCCore
import Testing
import WendyAgentGRPC

@testable import WendyAgentCore

@Suite("ContainerService.startContainer")
struct ContainerServiceTests {
    @Test("app updates are published for create, start, stop, and delete")
    func appUpdatesArePublishedForLifecycleChanges() async throws {
        let appsBase = try makeTempDir()
        defer { cleanup(appsBase) }

        let appID = "sh.wendy.tests.Lifecycle"
        let appDirectory = URL(fileURLWithPath: appsBase).appendingPathComponent(appID)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try writeSleepScript(to: appDirectory.appendingPathComponent("sleep.sh"))

        let recorder = AppSnapshotsRecorder()
        let service = ContainerService(
            broadcaster: TelemetryBroadcaster(),
            executablePath: "/usr/bin/false",
            appsBase: URL(fileURLWithPath: appsBase),
            onAppsChanged: { apps in
                await recorder.record(apps)
            }
        )

        try await registerFileSyncApp(service: service, appID: appID, cmd: "sleep.sh")
        #expect(await recorder.last() == .some([
            WendyAppInfo(id: appID, kind: .native, status: .stopped, pid: nil)
        ]))

        try await startApp(service: service, appID: appID)
        let runningSnapshot = try #require(await recorder.last())
        #expect(runningSnapshot.count == 1)
        #expect(runningSnapshot[0].id == appID)
        #expect(runningSnapshot[0].kind == .native)
        #expect(runningSnapshot[0].status == .running)
        #expect(runningSnapshot[0].pid != nil)

        try await stopApp(service: service, appID: appID)
        #expect(await recorder.last() == .some([
            WendyAppInfo(id: appID, kind: .native, status: .stopped, pid: nil)
        ]))

        try await deleteApp(service: service, appID: appID)
        #expect(await recorder.last() == .some([]))
    }

    @Test("spontaneous native exits publish a stopped app update")
    func spontaneousNativeExitPublishesStoppedAppUpdate() async throws {
        let appsBase = try makeTempDir()
        defer { cleanup(appsBase) }

        let appID = "sh.wendy.tests.ExitOnOwn"
        let appDirectory = URL(fileURLWithPath: appsBase).appendingPathComponent(appID)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try writeExitAfterDelayScript(to: appDirectory.appendingPathComponent("exit.sh"))

        let recorder = AppSnapshotsRecorder()
        let service = ContainerService(
            broadcaster: TelemetryBroadcaster(),
            executablePath: "/usr/bin/false",
            appsBase: URL(fileURLWithPath: appsBase),
            onAppsChanged: { apps in
                await recorder.record(apps)
            }
        )

        try await registerFileSyncApp(service: service, appID: appID, cmd: "exit.sh")
        try await startApp(service: service, appID: appID)

        try await waitUntil(description: "app starts running") {
            guard let info = await service.appInfo(forAppID: appID) else { return false }
            return info.status == .running && info.pid != nil
        }

        try await waitUntil(description: "app exits and becomes stopped") {
            await service.appInfo(forAppID: appID)
                == WendyAppInfo(id: appID, kind: .native, status: .stopped, pid: nil)
        }

        let snapshots = await recorder.snapshotValues()
        let publishedRunningSnapshot = snapshots.contains { snapshot in
            snapshot.count == 1
                && snapshot[0].id == appID
                && snapshot[0].kind == .native
                && snapshot[0].status == .running
                && snapshot[0].pid != nil
        }
        #expect(publishedRunningSnapshot)
        #expect(snapshots.last == [
            WendyAppInfo(id: appID, kind: .native, status: .stopped, pid: nil)
        ])
    }

    @Test("stale termination callbacks do not overwrite a newer launch")
    func staleTerminationCallbacksDoNotOverwriteANewerLaunch() async throws {
        let appsBase = try makeTempDir()
        defer { cleanup(appsBase) }

        let appID = "sh.wendy.tests.StaleTermination"
        let appDirectory = URL(fileURLWithPath: appsBase).appendingPathComponent(appID)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try writeSleepScript(to: appDirectory.appendingPathComponent("sleep.sh"))

        let recorder = AppSnapshotsRecorder()
        let service = ContainerService(
            broadcaster: TelemetryBroadcaster(),
            executablePath: "/usr/bin/false",
            appsBase: URL(fileURLWithPath: appsBase),
            onAppsChanged: { apps in
                await recorder.record(apps)
            }
        )

        try await registerFileSyncApp(service: service, appID: appID, cmd: "sleep.sh")
        try await startApp(service: service, appID: appID)

        try await waitUntil(description: "first launch token") {
            await service.launchToken(forAppID: appID) != nil
        }
        let firstLaunchToken = try #require(await service.launchToken(forAppID: appID))

        try await startApp(service: service, appID: appID)

        try await waitUntil(description: "second launch replaces the first launch token") {
            guard let info = await service.appInfo(forAppID: appID),
                  let token = await service.launchToken(forAppID: appID)
            else {
                return false
            }
            return info.status == .running && info.pid != nil && token != firstLaunchToken
        }

        let snapshotCountBefore = await recorder.count()
        await service.handleAppTermination(id: appID, launchToken: firstLaunchToken)
        let snapshotCountAfter = await recorder.count()
        let currentInfo = try #require(await service.appInfo(forAppID: appID))

        #expect(snapshotCountAfter == snapshotCountBefore)
        #expect(currentInfo.status == .running)
        #expect(currentInfo.pid != nil)

        try await stopApp(service: service, appID: appID)
    }

    @Test("file-sync native launch uses synced app directory as current working directory")
    func fileSyncLaunchUsesSyncedAppDirectoryAsCurrentWorkingDirectory() async throws {
        let appsBase = try makeTempDir()
        defer { cleanup(appsBase) }

        let appID = "sh.wendy.tests.PrintPWD"
        let appDirectory = URL(fileURLWithPath: appsBase).appendingPathComponent(appID)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        try writePrintPWDScript(to: appDirectory.appendingPathComponent("printpwd.sh"))

        let service = ContainerService(
            broadcaster: TelemetryBroadcaster(),
            executablePath: "/usr/bin/false",
            appsBase: URL(fileURLWithPath: appsBase)
        )

        try await registerFileSyncApp(service: service, appID: appID, cmd: "printpwd.sh")
        let stdout = try await startAppAndCollectStdout(service: service, appID: appID)
        let expectedPath = try canonicalPath(appDirectory.path)

        #expect(stdout == expectedPath)
    }

    @Test("sandboxed file-sync native launch uses synced app directory as current working directory")
    func sandboxedFileSyncLaunchUsesSyncedAppDirectoryAsCurrentWorkingDirectory() async throws {
        let appsBase = try makeTempDir()
        defer { cleanup(appsBase) }

        let appID = "sh.wendy.tests.PrintPWDSandboxed"
        let appDirectory = URL(fileURLWithPath: appsBase).appendingPathComponent(appID)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        try writePrintPWDScript(to: appDirectory.appendingPathComponent("printpwd.sh"))
        try writeSandboxProfile(to: appDirectory.appendingPathComponent("sandbox.sb"))

        let service = ContainerService(
            broadcaster: TelemetryBroadcaster(),
            executablePath: "/usr/bin/false",
            appsBase: URL(fileURLWithPath: appsBase)
        )

        try await registerFileSyncApp(service: service, appID: appID, cmd: "printpwd.sh")
        let stdout = try await startAppAndCollectStdout(service: service, appID: appID)
        let expectedPath = try canonicalPath(appDirectory.path)

        #expect(stdout == expectedPath)
    }

    @Test("listContainerStats reports registered apps with zeroed stats")
    func listContainerStatsReportsRegisteredApps() async throws {
        let appsBase = try makeTempDir()
        defer { cleanup(appsBase) }

        let appID = "sh.wendy.tests.Stats"
        let appDirectory = URL(fileURLWithPath: appsBase).appendingPathComponent(appID)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try writePrintPWDScript(to: appDirectory.appendingPathComponent("printpwd.sh"))

        let service = ContainerService(
            broadcaster: TelemetryBroadcaster(),
            executablePath: "/usr/bin/false",
            appsBase: URL(fileURLWithPath: appsBase)
        )

        try await registerFileSyncApp(service: service, appID: appID, cmd: "printpwd.sh")
        let stats = try await listContainerStats(service: service)

        #expect(stats.count == 1)
        #expect(stats.first?.appName == appID)
        #expect(stats.first?.memoryBytes == 0)
        #expect(stats.first?.storageBytes == 0)
    }
}

// MARK: - Helpers

private actor AppSnapshotsRecorder {
    private var storedSnapshots: [[WendyAppInfo]] = []

    func record(_ apps: [WendyAppInfo]) {
        self.storedSnapshots.append(apps)
    }

    func last() -> [WendyAppInfo]? {
        self.storedSnapshots.last
    }

    func count() -> Int {
        self.storedSnapshots.count
    }

    func snapshotValues() -> [[WendyAppInfo]] {
        self.storedSnapshots
    }
}

private final class CollectingWriter<Element: Sendable>: RPCWriterProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "wendy.tests.collecting-writer")
    private var elements: [Element] = []

    func write(_ element: Element) async throws {
        queue.sync {
            elements.append(element)
        }
    }

    func write(contentsOf elements: some Sequence<Element>) async throws {
        queue.sync {
            self.elements.append(contentsOf: elements)
        }
    }

    func snapshot() -> [Element] {
        queue.sync {
            elements
        }
    }
}

private struct TestError: Error, CustomStringConvertible {
    let description: String
}

private func registerFileSyncApp(
    service: ContainerService,
    appID: String,
    cmd: String
) async throws {
    var request = Wendy_Agent_Services_V1_CreateContainerRequest()
    request.appName = appID
    request.imageName = ""
    request.cmd = cmd

    _ = try await service.createContainer(
        request: ServerRequest(metadata: [:], message: request),
        context: makeServerContext(method: "CreateContainer")
    )
}

private func startApp(
    service: ContainerService,
    appID: String
) async throws {
    var request = Wendy_Agent_Services_V1_StartContainerRequest()
    request.appName = appID

    _ = try await service.startContainer(
        request: ServerRequest(metadata: [:], message: request),
        context: makeServerContext(method: "StartContainer")
    )
}

private func stopApp(
    service: ContainerService,
    appID: String
) async throws {
    var request = Wendy_Agent_Services_V1_StopContainerRequest()
    request.appName = appID

    _ = try await service.stopContainer(
        request: ServerRequest(metadata: [:], message: request),
        context: makeServerContext(method: "StopContainer")
    )
}

private func deleteApp(
    service: ContainerService,
    appID: String
) async throws {
    var request = Wendy_Agent_Services_V1_DeleteContainerRequest()
    request.appName = appID

    _ = try await service.deleteContainer(
        request: ServerRequest(metadata: [:], message: request),
        context: makeServerContext(method: "DeleteContainer")
    )
}

private func startAppAndCollectStdout(
    service: ContainerService,
    appID: String
) async throws -> String {
    var request = Wendy_Agent_Services_V1_StartContainerRequest()
    request.appName = appID

    let response = try await service.startContainer(
        request: ServerRequest(metadata: [:], message: request),
        context: makeServerContext(method: "StartContainer")
    )

    let contents = try response.accepted.get()
    let writer = CollectingWriter<Wendy_Agent_Services_V1_RunContainerLayersResponse>()
    _ = try await contents.producer(RPCWriter(wrapping: writer))

    let messages = writer.snapshot()
    let stdout = messages.reduce(into: Data()) { data, message in
        guard case .stdoutOutput(let output)? = message.responseType else { return }
        data.append(output.data)
    }
    let stderr = messages.reduce(into: Data()) { data, message in
        guard case .stderrOutput(let output)? = message.responseType else { return }
        data.append(output.data)
    }

    let stdoutText = String(decoding: stdout, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stderrText = String(decoding: stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if stdoutText.isEmpty, !stderrText.isEmpty {
        throw TestError(description: "Process produced no stdout. stderr: \(stderrText)")
    }

    return stdoutText
}

private func listContainerStats(
    service: ContainerService
) async throws -> [Wendy_Agent_Services_V1_ContainerStats] {
    let response = try await service.listContainerStats(
        request: ServerRequest(
            metadata: [:],
            message: Wendy_Agent_Services_V1_ListContainerStatsRequest()
        ),
        context: makeServerContext(method: "ListContainerStats")
    )
    return try response.message.stats
}

private func makeServerContext(method: String) -> ServerContext {
    ServerContext(
        descriptor: MethodDescriptor(
            fullyQualifiedService: "wendy.agent.services.v1.WendyContainerService",
            method: method
        ),
        remotePeer: "in-process:test",
        localPeer: "in-process:test",
        cancellation: .init()
    )
}

private func writePrintPWDScript(to url: URL) throws {
    try "#!/bin/sh\n/bin/pwd\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func writeSandboxProfile(to url: URL) throws {
    try "(version 1)\n(allow default)\n".write(to: url, atomically: true, encoding: .utf8)
}

private func writeSleepScript(to url: URL) throws {
    try "#!/bin/sh\nwhile true; do\n  sleep 1\ndone\n".write(
        to: url,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func writeExitAfterDelayScript(to url: URL) throws {
    try "#!/bin/sh\nsleep 0.2\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func makeTempDir() throws -> String {
    let path =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("wendy-test-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func canonicalPath(_ path: String) throws -> String {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard path.withCString({ realpath($0, &resolved) }) != nil else {
        throw TestError(description: "Failed to resolve canonical path for \(path)")
    }
    let count = resolved.firstIndex(of: 0) ?? resolved.count
    return String(decoding: resolved.prefix(count).map(UInt8.init(bitPattern:)), as: UTF8.self)
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

private func waitUntil(
    description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }

    throw TestError(description: "Timed out waiting for \(description)")
}
