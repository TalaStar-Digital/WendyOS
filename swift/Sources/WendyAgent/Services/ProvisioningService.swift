import GRPCCore
import WendyAgentGRPC

struct ProvisioningService: Wendy_Agent_Services_V1_WendyProvisioningService.SimpleServiceProtocol {
    func startProvisioning(
        request: Wendy_Agent_Services_V1_StartProvisioningRequest,
        context: ServerContext
    ) async throws -> Wendy_Agent_Services_V1_StartProvisioningResponse {
        fatalError("not implemented")
    }

    func isProvisioned(
        request: Wendy_Agent_Services_V1_IsProvisionedRequest,
        context: ServerContext
    ) async throws -> Wendy_Agent_Services_V1_IsProvisionedResponse {
        fatalError("not implemented")
    }
}
