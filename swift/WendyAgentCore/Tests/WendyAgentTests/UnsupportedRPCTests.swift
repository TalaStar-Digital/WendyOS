import GRPCCore
import Testing
import WendyAgentGRPC

@testable import WendyAgentCore

@Suite("Unsupported RPC contract")
struct UnsupportedRPCTests {
    @Test("agent service unsupported RPCs use the standardized macOS contract")
    func agentServiceUnsupportedRPCs() async {
        let service = AgentService()

        await assertUnsupportedCases([
            (
                "RunContainer",
                {
                    _ = try await service.runContainer(
                        request: makeStreamingRequest(
                            Wendy_Agent_Services_V1_RunContainerRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "RunContainer"
                        )
                    )
                }
            ),
            (
                "UpdateAgent",
                {
                    _ = try await service.updateAgent(
                        request: makeStreamingRequest(
                            Wendy_Agent_Services_V1_UpdateAgentRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "UpdateAgent"
                        )
                    )
                }
            ),
            (
                "ListWiFiNetworks",
                {
                    _ = try await service.listWiFiNetworks(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ListWiFiNetworksRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ListWiFiNetworks"
                        )
                    )
                }
            ),
            (
                "ConnectToWiFi",
                {
                    _ = try await service.connectToWiFi(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ConnectToWiFiRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ConnectToWiFi"
                        )
                    )
                }
            ),
            (
                "GetWiFiStatus",
                {
                    _ = try await service.getWiFiStatus(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_GetWiFiStatusRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "GetWiFiStatus"
                        )
                    )
                }
            ),
            (
                "DisconnectWiFi",
                {
                    _ = try await service.disconnectWiFi(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_DisconnectWiFiRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "DisconnectWiFi"
                        )
                    )
                }
            ),
            (
                "ListKnownWiFiNetworks",
                {
                    _ = try await service.listKnownWiFiNetworks(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ListKnownWiFiNetworksRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ListKnownWiFiNetworks"
                        )
                    )
                }
            ),
            (
                "SetWiFiNetworkPriority",
                {
                    _ = try await service.setWiFiNetworkPriority(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_SetWiFiNetworkPriorityRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "SetWiFiNetworkPriority"
                        )
                    )
                }
            ),
            (
                "ReorderKnownWiFiNetworks",
                {
                    _ = try await service.reorderKnownWiFiNetworks(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ReorderKnownWiFiNetworksRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ReorderKnownWiFiNetworks"
                        )
                    )
                }
            ),
            (
                "ForgetWiFiNetwork",
                {
                    _ = try await service.forgetWiFiNetwork(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ForgetWiFiNetworkRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ForgetWiFiNetwork"
                        )
                    )
                }
            ),
            (
                "ListHardwareCapabilities",
                {
                    _ = try await service.listHardwareCapabilities(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ListHardwareCapabilitiesRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ListHardwareCapabilities"
                        )
                    )
                }
            ),
            (
                "ScanBluetoothPeripherals",
                {
                    _ = try await service.scanBluetoothPeripherals(
                        request: makeStreamingRequest(
                            Wendy_Agent_Services_V1_ScanBluetoothPeripheralsRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ScanBluetoothPeripherals"
                        )
                    )
                }
            ),
            (
                "ConnectBluetoothPeripheral",
                {
                    _ = try await service.connectBluetoothPeripheral(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ConnectBluetoothPeripheralRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ConnectBluetoothPeripheral"
                        )
                    )
                }
            ),
            (
                "DisconnectBluetoothPeripheral",
                {
                    _ = try await service.disconnectBluetoothPeripheral(
                        request: ServerRequest(
                            metadata: [:],
                            message:
                                Wendy_Agent_Services_V1_DisconnectBluetoothPeripheralRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "DisconnectBluetoothPeripheral"
                        )
                    )
                }
            ),
            (
                "ForgetBluetoothPeripheral",
                {
                    _ = try await service.forgetBluetoothPeripheral(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ForgetBluetoothPeripheralRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "ForgetBluetoothPeripheral"
                        )
                    )
                }
            ),
            (
                "UpdateOS",
                {
                    _ = try await service.updateOS(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_UpdateOSRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAgentService",
                            method: "UpdateOS"
                        )
                    )
                }
            ),
        ])
    }

    @Test("audio service unsupported RPCs use the standardized macOS contract")
    func audioServiceUnsupportedRPCs() async {
        let service = AudioService()

        await assertUnsupportedCases([
            (
                "ListAudioDevices",
                {
                    _ = try await service.listAudioDevices(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ListAudioDevicesRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAudioService",
                            method: "ListAudioDevices"
                        )
                    )
                }
            ),
            (
                "SetDefaultAudioDevice",
                {
                    _ = try await service.setDefaultAudioDevice(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_SetDefaultAudioDeviceRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAudioService",
                            method: "SetDefaultAudioDevice"
                        )
                    )
                }
            ),
            (
                "StreamAudioLevels",
                {
                    _ = try await service.streamAudioLevels(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_StreamAudioLevelsRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAudioService",
                            method: "StreamAudioLevels"
                        )
                    )
                }
            ),
            (
                "StreamAudio",
                {
                    _ = try await service.streamAudio(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_StreamAudioRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyAudioService",
                            method: "StreamAudio"
                        )
                    )
                }
            ),
        ])
    }

    @Test("container service placeholder RPCs use the standardized macOS contract")
    func containerServiceUnsupportedRPCs() async {
        let service = ContainerService(
            broadcaster: TelemetryBroadcaster(),
            executablePath: "/usr/bin/false"
        )

        await assertUnsupportedCases([
            (
                "AttachContainer",
                {
                    _ = try await service.attachContainer(
                        request: makeStreamingRequest(
                            Wendy_Agent_Services_V1_AttachContainerRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyContainerService",
                            method: "AttachContainer"
                        )
                    )
                }
            ),
            (
                "ListVolumes",
                {
                    _ = try await service.listVolumes(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ListVolumesRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyContainerService",
                            method: "ListVolumes"
                        )
                    )
                }
            ),
            (
                "RemoveVolume",
                {
                    _ = try await service.removeVolume(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_RemoveVolumeRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyContainerService",
                            method: "RemoveVolume"
                        )
                    )
                }
            ),
            (
                "ListLayers",
                {
                    _ = try await service.listLayers(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_ListLayersRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyContainerService",
                            method: "ListLayers"
                        )
                    )
                }
            ),
            (
                "CreateContainerWithProgress",
                {
                    _ = try await service.createContainerWithProgress(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_CreateContainerRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyContainerService",
                            method: "CreateContainerWithProgress"
                        )
                    )
                }
            ),
            (
                "RunContainer",
                {
                    _ = try await service.runContainer(
                        request: ServerRequest(
                            metadata: [:],
                            message: Wendy_Agent_Services_V1_RunContainerLayersRequest()
                        ),
                        context: makeServerContext(
                            service: "wendy.agent.services.v1.WendyContainerService",
                            method: "RunContainer"
                        )
                    )
                }
            ),
        ])
    }

    @Test("agent version prefers bundle metadata before fallback sources")
    func agentVersionPrefersBundleMetadata() {
        #expect(
            AgentVersion.resolve(
                bundleInfo: [
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "123"
                ],
                environment: [AgentVersion.environmentVariable: "9.9.9"]
            ) == "1.2.3"
        )
    }

    @Test("agent version uses environment override when bundle metadata is missing")
    func agentVersionUsesEnvironmentFallback() {
        #expect(
            AgentVersion.resolve(
                bundleInfo: nil,
                environment: [AgentVersion.environmentVariable: "2.3.4-test"]
            ) == "2.3.4-test"
        )
    }

    @Test("agent version ignores placeholder bundle values before falling back")
    func agentVersionIgnoresPlaceholderBundleValues() {
        #expect(
            AgentVersion.resolve(
                bundleInfo: [
                    "CFBundleShortVersionString": "0000.00.00",
                    "CFBundleVersion": "00000000000000"
                ],
                environment: [AgentVersion.environmentVariable: "3.4.5-test"]
            ) == "3.4.5-test"
        )
    }

    @Test("agent version falls back to the development version only when needed")
    func agentVersionFallsBackToDevelopmentVersion() {
        #expect(AgentVersion.resolve(bundleInfo: nil, environment: [:]) == AgentVersion.fallback)
    }

    @Test("getAgentVersion reports the resolved version and platform metadata")
    func getAgentVersionUsesResolvedVersion() async throws {
        let service = AgentService()
        let response = try await service.getAgentVersion(
            request: ServerRequest(
                metadata: [:],
                message: Wendy_Agent_Services_V1_GetAgentVersionRequest()
            ),
            context: makeServerContext(
                service: "wendy.agent.services.v1.WendyAgentService",
                method: "GetAgentVersion"
            )
        )
        let message = try response.message

        #expect(message.version == AgentVersion.current)
        #expect(message.os == "darwin")
        #expect(!message.osVersion.isEmpty)
        #expect(["arm64", "amd64", "unknown"].contains(message.cpuArchitecture))
    }
}

private typealias UnsupportedCase = (name: String, call: @Sendable () async throws -> Void)

private func assertUnsupportedCases(_ cases: [UnsupportedCase]) async {
    for unsupportedCase in cases {
        await assertUnsupported(unsupportedCase.name, unsupportedCase.call)
    }
}

private func assertUnsupported(
    _ name: String,
    _ call: @escaping @Sendable () async throws -> Void
) async {
    do {
        try await call()
        Issue.record("Expected \(name) to be unsupported")
    } catch let error as RPCError {
        #expect(UnsupportedRPC.isUnsupported(error), "\(name) should use UnsupportedRPC")
        #expect(error.message == UnsupportedRPC.message)
    } catch {
        Issue.record("Expected \(name) to throw RPCError, got \(error)")
    }
}

private func makeServerContext(service: String, method: String) -> ServerContext {
    ServerContext(
        descriptor: MethodDescriptor(fullyQualifiedService: service, method: method),
        remotePeer: "in-process:test",
        localPeer: "in-process:test",
        cancellation: .init()
    )
}

private func makeStreamingRequest<Message: Sendable>(
    _ message: Message
) -> StreamingServerRequest<Message> {
    StreamingServerRequest(
        metadata: [:],
        messages: RPCAsyncSequence(
            wrapping: AsyncThrowingStream<Message, any Error> { continuation in
                continuation.yield(message)
                continuation.finish()
            }
        )
    )
}
