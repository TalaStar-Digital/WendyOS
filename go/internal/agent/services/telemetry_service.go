package services

import (
	"context"
	"fmt"
	"sync"

	"go.uber.org/zap"
	"google.golang.org/grpc"

	agentpb "github.com/wendylabsinc/wendy/proto/gen/agentpb"
	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

// TelemetryBroadcaster fans out received OTEL telemetry to multiple connected clients.
type TelemetryBroadcaster struct {
	mu         sync.RWMutex
	logSubs    map[string]chan *otelpb.ExportLogsServiceRequest
	metricSubs map[string]chan *otelpb.ExportMetricsServiceRequest
	traceSubs  map[string]chan *otelpb.ExportTraceServiceRequest
	nextID     uint64
}

// NewTelemetryBroadcaster creates a new TelemetryBroadcaster.
func NewTelemetryBroadcaster() *TelemetryBroadcaster {
	return &TelemetryBroadcaster{
		logSubs:    make(map[string]chan *otelpb.ExportLogsServiceRequest),
		metricSubs: make(map[string]chan *otelpb.ExportMetricsServiceRequest),
		traceSubs:  make(map[string]chan *otelpb.ExportTraceServiceRequest),
	}
}

func (b *TelemetryBroadcaster) nextSubID() string {
	b.nextID++
	return fmt.Sprintf("sub-%d", b.nextID)
}

// SubscribeLogs adds a log subscriber and returns the channel and subscription ID.
func (b *TelemetryBroadcaster) SubscribeLogs() (string, <-chan *otelpb.ExportLogsServiceRequest) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id := b.nextSubID()
	ch := make(chan *otelpb.ExportLogsServiceRequest, 64)
	b.logSubs[id] = ch
	return id, ch
}

// UnsubscribeLogs removes a log subscriber.
func (b *TelemetryBroadcaster) UnsubscribeLogs(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ch, ok := b.logSubs[id]; ok {
		close(ch)
		delete(b.logSubs, id)
	}
}

// PublishLogs sends a log export request to all log subscribers.
func (b *TelemetryBroadcaster) PublishLogs(req *otelpb.ExportLogsServiceRequest) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	for _, ch := range b.logSubs {
		select {
		case ch <- req:
		default:
			// Drop if subscriber is slow.
		}
	}
}

// SubscribeMetrics adds a metrics subscriber.
func (b *TelemetryBroadcaster) SubscribeMetrics() (string, <-chan *otelpb.ExportMetricsServiceRequest) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id := b.nextSubID()
	ch := make(chan *otelpb.ExportMetricsServiceRequest, 64)
	b.metricSubs[id] = ch
	return id, ch
}

// UnsubscribeMetrics removes a metrics subscriber.
func (b *TelemetryBroadcaster) UnsubscribeMetrics(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ch, ok := b.metricSubs[id]; ok {
		close(ch)
		delete(b.metricSubs, id)
	}
}

// PublishMetrics sends a metrics export request to all metrics subscribers.
func (b *TelemetryBroadcaster) PublishMetrics(req *otelpb.ExportMetricsServiceRequest) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	for _, ch := range b.metricSubs {
		select {
		case ch <- req:
		default:
		}
	}
}

// SubscribeTraces adds a traces subscriber.
func (b *TelemetryBroadcaster) SubscribeTraces() (string, <-chan *otelpb.ExportTraceServiceRequest) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id := b.nextSubID()
	ch := make(chan *otelpb.ExportTraceServiceRequest, 64)
	b.traceSubs[id] = ch
	return id, ch
}

// UnsubscribeTraces removes a traces subscriber.
func (b *TelemetryBroadcaster) UnsubscribeTraces(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ch, ok := b.traceSubs[id]; ok {
		close(ch)
		delete(b.traceSubs, id)
	}
}

// PublishTraces sends a trace export request to all trace subscribers.
func (b *TelemetryBroadcaster) PublishTraces(req *otelpb.ExportTraceServiceRequest) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	for _, ch := range b.traceSubs {
		select {
		case ch <- req:
		default:
		}
	}
}

// TelemetryService implements agentpb.WendyTelemetryServiceServer.
type TelemetryService struct {
	agentpb.UnimplementedWendyTelemetryServiceServer
	logger      *zap.Logger
	broadcaster *TelemetryBroadcaster
}

// NewTelemetryService creates a new TelemetryService.
func NewTelemetryService(logger *zap.Logger, broadcaster *TelemetryBroadcaster) *TelemetryService {
	return &TelemetryService{
		logger:      logger,
		broadcaster: broadcaster,
	}
}

// Broadcaster returns the underlying broadcaster for publishing telemetry data.
func (s *TelemetryService) Broadcaster() *TelemetryBroadcaster {
	return s.broadcaster
}

// StreamLogs streams filtered log records to the client.
func (s *TelemetryService) StreamLogs(req *agentpb.StreamLogsRequest, stream grpc.ServerStreamingServer[agentpb.StreamLogsResponse]) error {
	ctx := stream.Context()

	id, ch := s.broadcaster.SubscribeLogs()
	defer s.broadcaster.UnsubscribeLogs(id)

	s.logger.Info("StreamLogs client connected", zap.String("sub_id", id))

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case logReq, ok := <-ch:
			if !ok {
				return nil
			}

			// Apply filters if requested.
			if req.AppName != nil || req.ServiceName != nil || req.MinSeverity != nil {
				logReq = filterLogs(logReq, req)
				if logReq == nil {
					continue
				}
			}

			if err := stream.Send(&agentpb.StreamLogsResponse{
				Logs: logReq,
			}); err != nil {
				return err
			}
		}
	}
}

// StreamMetrics streams filtered metrics to the client.
func (s *TelemetryService) StreamMetrics(req *agentpb.StreamMetricsRequest, stream grpc.ServerStreamingServer[agentpb.StreamMetricsResponse]) error {
	ctx := stream.Context()

	id, ch := s.broadcaster.SubscribeMetrics()
	defer s.broadcaster.UnsubscribeMetrics(id)

	s.logger.Info("StreamMetrics client connected", zap.String("sub_id", id))

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case metricsReq, ok := <-ch:
			if !ok {
				return nil
			}

			if err := stream.Send(&agentpb.StreamMetricsResponse{
				Metrics: metricsReq,
			}); err != nil {
				return err
			}
		}
	}
}

// StreamTraces streams filtered traces to the client.
func (s *TelemetryService) StreamTraces(req *agentpb.StreamTracesRequest, stream grpc.ServerStreamingServer[agentpb.StreamTracesResponse]) error {
	ctx := stream.Context()

	id, ch := s.broadcaster.SubscribeTraces()
	defer s.broadcaster.UnsubscribeTraces(id)

	s.logger.Info("StreamTraces client connected", zap.String("sub_id", id))

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case traceReq, ok := <-ch:
			if !ok {
				return nil
			}

			if err := stream.Send(&agentpb.StreamTracesResponse{
				Traces: traceReq,
			}); err != nil {
				return err
			}
		}
	}
}

// OTELLogsReceiver implements otelpb.LogsServiceServer so the agent can receive
// OTEL logs from containers and broadcast them to CLI clients.
type OTELLogsReceiver struct {
	otelpb.UnimplementedLogsServiceServer
	broadcaster *TelemetryBroadcaster
}

// NewOTELLogsReceiver creates a new OTELLogsReceiver.
func NewOTELLogsReceiver(b *TelemetryBroadcaster) *OTELLogsReceiver {
	return &OTELLogsReceiver{broadcaster: b}
}

// Export receives OTEL logs and fans them out to subscribers.
func (r *OTELLogsReceiver) Export(_ context.Context, req *otelpb.ExportLogsServiceRequest) (*otelpb.ExportLogsServiceResponse, error) {
	r.broadcaster.PublishLogs(req)
	return &otelpb.ExportLogsServiceResponse{}, nil
}

// OTELMetricsReceiver implements otelpb.MetricsServiceServer.
type OTELMetricsReceiver struct {
	otelpb.UnimplementedMetricsServiceServer
	broadcaster *TelemetryBroadcaster
}

// NewOTELMetricsReceiver creates a new OTELMetricsReceiver.
func NewOTELMetricsReceiver(b *TelemetryBroadcaster) *OTELMetricsReceiver {
	return &OTELMetricsReceiver{broadcaster: b}
}

// Export receives OTEL metrics and fans them out to subscribers.
func (r *OTELMetricsReceiver) Export(_ context.Context, req *otelpb.ExportMetricsServiceRequest) (*otelpb.ExportMetricsServiceResponse, error) {
	r.broadcaster.PublishMetrics(req)
	return &otelpb.ExportMetricsServiceResponse{}, nil
}

// OTELTraceReceiver implements otelpb.TraceServiceServer.
type OTELTraceReceiver struct {
	otelpb.UnimplementedTraceServiceServer
	broadcaster *TelemetryBroadcaster
}

// NewOTELTraceReceiver creates a new OTELTraceReceiver.
func NewOTELTraceReceiver(b *TelemetryBroadcaster) *OTELTraceReceiver {
	return &OTELTraceReceiver{broadcaster: b}
}

// Export receives OTEL traces and fans them out to subscribers.
func (r *OTELTraceReceiver) Export(_ context.Context, req *otelpb.ExportTraceServiceRequest) (*otelpb.ExportTraceServiceResponse, error) {
	r.broadcaster.PublishTraces(req)
	return &otelpb.ExportTraceServiceResponse{}, nil
}

// filterLogs filters log records based on the stream request filters.
// Returns nil if all records are filtered out.
func filterLogs(req *otelpb.ExportLogsServiceRequest, filter *agentpb.StreamLogsRequest) *otelpb.ExportLogsServiceRequest {
	// For now, pass through all logs. A full implementation would filter by
	// service name, severity, and app name by inspecting resource attributes
	// and log record fields.
	_ = filter
	return req
}

// Ensure compile-time interface compliance.
var (
	_ agentpb.WendyTelemetryServiceServer = (*TelemetryService)(nil)
	_ otelpb.LogsServiceServer            = (*OTELLogsReceiver)(nil)
	_ otelpb.MetricsServiceServer         = (*OTELMetricsReceiver)(nil)
	_ otelpb.TraceServiceServer           = (*OTELTraceReceiver)(nil)
)
