import Foundation
import GRPCCore
import WendyAgentGRPC

struct AgentService: Wendy_Agent_Services_V1_WendyAgentService.ServiceProtocol {
    func runContainer(
        request: StreamingServerRequest<Wendy_Agent_Services_V1_RunContainerRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_RunContainerResponse> {
        throw UnsupportedRPC.error()
    }

    func updateAgent(
        request: StreamingServerRequest<Wendy_Agent_Services_V1_UpdateAgentRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_UpdateAgentResponse> {
        throw UnsupportedRPC.error()
    }

    func getAgentVersion(
        request: ServerRequest<Wendy_Agent_Services_V1_GetAgentVersionRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_GetAgentVersionResponse> {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        var response = Wendy_Agent_Services_V1_GetAgentVersionResponse()
        response.version = AgentVersion.current
        response.os = "darwin"
        response.osVersion =
            "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        #if arch(arm64)
            response.cpuArchitecture = "arm64"
        #elseif arch(x86_64)
            response.cpuArchitecture = "amd64"
        #else
            response.cpuArchitecture = "unknown"
        #endif
        return ServerResponse(message: response)
    }

    func listWiFiNetworks(
        request: ServerRequest<Wendy_Agent_Services_V1_ListWiFiNetworksRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ListWiFiNetworksResponse> {
        throw UnsupportedRPC.error()
    }

    func connectToWiFi(
        request: ServerRequest<Wendy_Agent_Services_V1_ConnectToWiFiRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ConnectToWiFiResponse> {
        throw UnsupportedRPC.error()
    }

    func getWiFiStatus(
        request: ServerRequest<Wendy_Agent_Services_V1_GetWiFiStatusRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_GetWiFiStatusResponse> {
        throw UnsupportedRPC.error()
    }

    func disconnectWiFi(
        request: ServerRequest<Wendy_Agent_Services_V1_DisconnectWiFiRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_DisconnectWiFiResponse> {
        throw UnsupportedRPC.error()
    }

    func listKnownWiFiNetworks(
        request: ServerRequest<Wendy_Agent_Services_V1_ListKnownWiFiNetworksRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ListKnownWiFiNetworksResponse> {
        throw UnsupportedRPC.error()
    }

    func setWiFiNetworkPriority(
        request: ServerRequest<Wendy_Agent_Services_V1_SetWiFiNetworkPriorityRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_SetWiFiNetworkPriorityResponse> {
        throw UnsupportedRPC.error()
    }

    func reorderKnownWiFiNetworks(
        request: ServerRequest<Wendy_Agent_Services_V1_ReorderKnownWiFiNetworksRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ReorderKnownWiFiNetworksResponse> {
        throw UnsupportedRPC.error()
    }

    func forgetWiFiNetwork(
        request: ServerRequest<Wendy_Agent_Services_V1_ForgetWiFiNetworkRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ForgetWiFiNetworkResponse> {
        throw UnsupportedRPC.error()
    }

    func listHardwareCapabilities(
        request: ServerRequest<Wendy_Agent_Services_V1_ListHardwareCapabilitiesRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ListHardwareCapabilitiesResponse> {
        throw UnsupportedRPC.error()
    }

    func scanBluetoothPeripherals(
        request: StreamingServerRequest<Wendy_Agent_Services_V1_ScanBluetoothPeripheralsRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<
        Wendy_Agent_Services_V1_ScanBluetoothPeripheralsResponse
    > {
        throw UnsupportedRPC.error()
    }

    func connectBluetoothPeripheral(
        request: ServerRequest<Wendy_Agent_Services_V1_ConnectBluetoothPeripheralRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ConnectBluetoothPeripheralResponse> {
        throw UnsupportedRPC.error()
    }

    func disconnectBluetoothPeripheral(
        request: ServerRequest<Wendy_Agent_Services_V1_DisconnectBluetoothPeripheralRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_DisconnectBluetoothPeripheralResponse>
    {
        throw UnsupportedRPC.error()
    }

    func forgetBluetoothPeripheral(
        request: ServerRequest<Wendy_Agent_Services_V1_ForgetBluetoothPeripheralRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Wendy_Agent_Services_V1_ForgetBluetoothPeripheralResponse> {
        throw UnsupportedRPC.error()
    }

    func updateOS(
        request: ServerRequest<Wendy_Agent_Services_V1_UpdateOSRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wendy_Agent_Services_V1_UpdateOSResponse> {
        throw UnsupportedRPC.error()
    }
}
