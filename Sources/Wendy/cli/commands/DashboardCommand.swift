import ArgumentParser
import Foundation
import GRPCCore
import Noora
import OpenTelemetryGRPC
import WendyAgentGRPC

struct MetricsDashboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Live dashboard showing device metrics."
    )

    @Option(name: .shortAndLong, help: "Refresh interval in seconds")
    var interval: Double = 1.0

    @OptionGroup var agentConnectionOptions: AgentConnectionOptions

    func run() async throws {
        let endpoint = try await agentConnectionOptions.read(
            title: "For which device do you want to view the dashboard?"
        )

        let dashboard = MetricsDashboard()

        // Start the metrics streaming in background
        let streamTask = Task {
            while !Task.isCancelled {
                do {
                    try await withAgentGRPCClient(endpoint, title: "") { client in
                        let telemetry = Wendy_Agent_Services_V1_WendyTelemetryService.Client(wrapping: client)

                        let request = Wendy_Agent_Services_V1_StreamMetricsRequest()

                        try await telemetry.streamMetrics(request) { response in
                            switch response.accepted {
                            case .success(let contents):
                                for try await bodyPart in contents.bodyParts {
                                    switch bodyPart {
                                    case .message(let message):
                                        await dashboard.update(with: message.metrics)
                                    case .trailingMetadata:
                                        break
                                    }
                                }
                            case .failure(let error):
                                throw error
                            }
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    await dashboard.setConnectionStatus(connected: false)
                    try await Task.sleep(for: .seconds(2))
                }
            }
        }

        // Render loop
        await dashboard.setConnectionStatus(connected: true)
        while !Task.isCancelled {
            await dashboard.render()
            try await Task.sleep(for: .seconds(interval))
        }

        streamTask.cancel()
    }
}

actor MetricsDashboard {
    private var metrics: [String: MetricData] = [:]
    private var lastUpdate: Date?
    private var isConnected = false
    private var deviceName: String = "Device"

    struct MetricData {
        let name: String
        let service: String
        var value: String
        var unit: String
        var timestamp: Date
    }

    func setConnectionStatus(connected: Bool) {
        isConnected = connected
    }

    func update(with metricsRequest: Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest) {
        lastUpdate = Date()
        isConnected = true

        for resourceMetrics in metricsRequest.resourceMetrics {
            let serviceName = resourceMetrics.resource.attributes
                .first { $0.key == "service.name" }?.value.stringValue ?? "unknown"

            for scopeMetrics in resourceMetrics.scopeMetrics {
                for metric in scopeMetrics.metrics {
                    let key = "\(serviceName):\(metric.name)"
                    metrics[key] = MetricData(
                        name: metric.name,
                        service: serviceName,
                        value: formatValue(metric),
                        unit: metric.unit,
                        timestamp: Date()
                    )
                }
            }
        }
    }

    func render() {
        // Clear screen and move cursor to top
        print("\u{001B}[2J\u{001B}[H", terminator: "")

        // Header
        let header = """
        ╔════════════════════════════════════════════════════════════════════════════╗
        ║                         WENDY DEVICE DASHBOARD                             ║
        ╚════════════════════════════════════════════════════════════════════════════╝
        """
        print(header)

        // Connection status
        let statusIcon = isConnected ? "●" : "○"
        let statusColor = isConnected ? "\u{001B}[32m" : "\u{001B}[31m"
        let resetColor = "\u{001B}[0m"
        print("\(statusColor)\(statusIcon)\(resetColor) Status: \(isConnected ? "Connected" : "Disconnected")")

        if let lastUpdate {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            print("  Last update: \(formatter.string(from: lastUpdate))")
        }
        print()

        if metrics.isEmpty {
            print("  Waiting for metrics...")
            print()
            print("  Press Ctrl+C to exit")
            return
        }

        // Group metrics by service
        let grouped = Dictionary(grouping: metrics.values) { $0.service }

        for (service, serviceMetrics) in grouped.sorted(by: { $0.key < $1.key }) {
            print("┌─ \u{001B}[1m\(service)\u{001B}[0m")

            let sortedMetrics = serviceMetrics.sorted { $0.name < $1.name }
            for (index, metric) in sortedMetrics.enumerated() {
                let prefix = index == sortedMetrics.count - 1 ? "└" : "├"
                let unitStr = metric.unit.isEmpty ? "" : " \(metric.unit)"
                let valueStr = formatDisplayValue(metric.value, unit: metric.unit)
                print("\(prefix)── \(metric.name): \(valueStr)\(unitStr)")
            }
            print()
        }

        print("Press Ctrl+C to exit")
    }

    private func formatValue(_ metric: Opentelemetry_Proto_Metrics_V1_Metric) -> String {
        switch metric.data {
        case .gauge(let gauge):
            if let point = gauge.dataPoints.last {
                switch point.value {
                case .asDouble(let d): return String(format: "%.2f", d)
                case .asInt(let i): return String(i)
                default: return "N/A"
                }
            }
        case .sum(let sum):
            if let point = sum.dataPoints.last {
                switch point.value {
                case .asDouble(let d): return String(format: "%.2f", d)
                case .asInt(let i): return String(i)
                default: return "N/A"
                }
            }
        case .histogram(let histogram):
            if let point = histogram.dataPoints.last {
                return String(format: "%.2f", point.sum / Double(max(point.count, 1)))
            }
        case .summary(let summary):
            if let point = summary.dataPoints.last {
                return String(format: "%.2f", point.sum / Double(max(point.count, 1)))
            }
        default:
            break
        }
        return "N/A"
    }

    private func formatDisplayValue(_ value: String, unit: String) -> String {
        guard let doubleValue = Double(value) else { return value }

        // Format bytes
        if unit == "By" || unit == "bytes" {
            if doubleValue >= 1_073_741_824 {
                return String(format: "%.1f GB", doubleValue / 1_073_741_824)
            } else if doubleValue >= 1_048_576 {
                return String(format: "%.1f MB", doubleValue / 1_048_576)
            } else if doubleValue >= 1024 {
                return String(format: "%.1f KB", doubleValue / 1024)
            }
            return String(format: "%.0f B", doubleValue)
        }

        // Format percentages
        if unit == "%" || unit == "1" {
            return String(format: "%.1f%%", doubleValue * (unit == "1" ? 100 : 1))
        }

        // Format durations
        if unit == "s" || unit == "seconds" {
            if doubleValue < 0.001 {
                return String(format: "%.2f µs", doubleValue * 1_000_000)
            } else if doubleValue < 1 {
                return String(format: "%.2f ms", doubleValue * 1000)
            }
            return String(format: "%.2f s", doubleValue)
        }

        return value
    }
}
