import GRPCCore
import OpenTelemetryGRPC
import WendyAgentGRPC

struct TelemetryService: Wendy_Agent_Services_V1_WendyTelemetryService.SimpleServiceProtocol {
    func streamLogs(
        request: Wendy_Agent_Services_V1_StreamLogsRequest,
        response: RPCWriter<Wendy_Agent_Services_V1_StreamLogsResponse>,
        context: ServerContext
    ) async throws {
        fatalError("not implemented")
    }

    func streamMetrics(
        request: Wendy_Agent_Services_V1_StreamMetricsRequest,
        response: RPCWriter<Wendy_Agent_Services_V1_StreamMetricsResponse>,
        context: ServerContext
    ) async throws {
        fatalError("not implemented")
    }

    func streamTraces(
        request: Wendy_Agent_Services_V1_StreamTracesRequest,
        response: RPCWriter<Wendy_Agent_Services_V1_StreamTracesResponse>,
        context: ServerContext
    ) async throws {
        fatalError("not implemented")
    }
}
