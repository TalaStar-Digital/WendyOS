package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"runtime"
	"testing"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"

	"github.com/wendylabsinc/wendy/internal/agent/services"
	"github.com/wendylabsinc/wendy/internal/shared/appconfig"
	"github.com/wendylabsinc/wendy/internal/shared/version"
	agentpb "github.com/wendylabsinc/wendy/proto/gen/agentpb"
	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

// ---------- mocks for integration test ----------

type integrationNetworkManager struct{}

func (m *integrationNetworkManager) ListWiFiNetworks(_ context.Context) ([]*agentpb.ListWiFiNetworksResponse_WiFiNetwork, error) {
	return []*agentpb.ListWiFiNetworksResponse_WiFiNetwork{
		{Ssid: "IntegrationNet"},
	}, nil
}
func (m *integrationNetworkManager) ConnectToWiFi(_ context.Context, _, _ string) error {
	return nil
}
func (m *integrationNetworkManager) GetWiFiStatus(_ context.Context) (bool, string, error) {
	return true, "IntegrationNet", nil
}
func (m *integrationNetworkManager) DisconnectWiFi(_ context.Context) error {
	return nil
}

type integrationHardwareDiscoverer struct{}

func (m *integrationHardwareDiscoverer) Discover(_ context.Context, _ string) ([]*agentpb.ListHardwareCapabilitiesResponse_HardwareCapability, error) {
	return []*agentpb.ListHardwareCapabilitiesResponse_HardwareCapability{
		{Category: "gpu", DevicePath: "/dev/nvidia0", Description: "Test GPU"},
	}, nil
}

type integrationBluetoothManager struct{}

func (m *integrationBluetoothManager) Scan(_ context.Context) (<-chan []*agentpb.DiscoveredBluetoothPeripheral, error) {
	ch := make(chan []*agentpb.DiscoveredBluetoothPeripheral)
	close(ch)
	return ch, nil
}
func (m *integrationBluetoothManager) Connect(_ context.Context, _ string, _, _ bool) error {
	return nil
}
func (m *integrationBluetoothManager) Disconnect(_ context.Context, _ string) error { return nil }
func (m *integrationBluetoothManager) Forget(_ context.Context, _ string) error     { return nil }

type integrationContainerdClient struct{}

func (m *integrationContainerdClient) ListContainers(_ context.Context) ([]*agentpb.AppContainer, error) {
	return nil, nil // empty list
}
func (m *integrationContainerdClient) StopContainer(_ context.Context, _ string) error {
	return nil
}
func (m *integrationContainerdClient) DeleteContainer(_ context.Context, _ string, _ bool) error {
	return nil
}
func (m *integrationContainerdClient) ListLayers(_ context.Context) ([]*agentpb.LayerHeader, error) {
	return nil, nil
}
func (m *integrationContainerdClient) WriteLayer(_ context.Context, _ string, r io.Reader, _ int64) error {
	// Drain the reader to simulate writing.
	_, _ = io.Copy(io.Discard, r)
	return nil
}
func (m *integrationContainerdClient) CreateContainer(_ context.Context, _ *agentpb.CreateContainerRequest, _ *appconfig.AppConfig) error {
	return nil
}
func (m *integrationContainerdClient) StartContainer(_ context.Context, _ string) (<-chan services.ContainerOutput, error) {
	ch := make(chan services.ContainerOutput)
	close(ch)
	return ch, nil
}

// ---------- integration test ----------

const integrationBufSize = 1024 * 1024

func TestFullAgentLifecycle(t *testing.T) {
	logger := zap.NewNop()
	lis := bufconn.Listen(integrationBufSize)

	// Create all services.
	nm := &integrationNetworkManager{}
	hd := &integrationHardwareDiscoverer{}
	bm := &integrationBluetoothManager{}
	cc := &integrationContainerdClient{}

	agentSvc := services.NewAgentService(logger, nm, hd, bm)
	containerSvc := services.NewContainerService(logger, cc)
	broadcaster := services.NewTelemetryBroadcaster()
	telemetrySvc := services.NewTelemetryService(logger, broadcaster)
	otelLogs := services.NewOTELLogsReceiver(broadcaster)

	// Register all services on a single gRPC server.
	srv := grpc.NewServer()
	agentpb.RegisterWendyAgentServiceServer(srv, agentSvc)
	agentpb.RegisterWendyContainerServiceServer(srv, containerSvc)
	agentpb.RegisterWendyTelemetryServiceServer(srv, telemetrySvc)
	otelpb.RegisterLogsServiceServer(srv, otelLogs)

	go func() { _ = srv.Serve(lis) }()
	defer func() {
		srv.Stop()
		lis.Close()
	}()

	// Connect client.
	dialer := func(context.Context, string) (net.Conn, error) {
		return lis.Dial()
	}
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(dialer),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("grpc.NewClient: %v", err)
	}
	defer conn.Close()

	agentClient := agentpb.NewWendyAgentServiceClient(conn)
	containerClient := agentpb.NewWendyContainerServiceClient(conn)
	telemetryClient := agentpb.NewWendyTelemetryServiceClient(conn)
	otelLogsClient := otelpb.NewLogsServiceClient(conn)

	ctx := context.Background()

	// Step 1: GetAgentVersion
	t.Run("GetAgentVersion", func(t *testing.T) {
		resp, err := agentClient.GetAgentVersion(ctx, &agentpb.GetAgentVersionRequest{})
		if err != nil {
			t.Fatalf("GetAgentVersion: %v", err)
		}
		if resp.Version != version.Version {
			t.Errorf("version = %q; want %q", resp.Version, version.Version)
		}
		if resp.Os != runtime.GOOS {
			t.Errorf("os = %q; want %q", resp.Os, runtime.GOOS)
		}
		if resp.CpuArchitecture != runtime.GOARCH {
			t.Errorf("arch = %q; want %q", resp.CpuArchitecture, runtime.GOARCH)
		}
		t.Logf("Agent version: %s (%s/%s)", resp.Version, resp.Os, resp.CpuArchitecture)
	})

	// Step 2: ListContainers (empty)
	t.Run("ListContainers_Empty", func(t *testing.T) {
		stream, err := containerClient.ListContainers(ctx, &agentpb.ListContainersRequest{})
		if err != nil {
			t.Fatalf("ListContainers: %v", err)
		}

		var containers []*agentpb.AppContainer
		for {
			resp, err := stream.Recv()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatalf("recv: %v", err)
			}
			containers = append(containers, resp.Container)
		}

		if len(containers) != 0 {
			t.Errorf("expected 0 containers, got %d", len(containers))
		}
	})

	// Step 3: ListHardwareCapabilities
	t.Run("ListHardwareCapabilities", func(t *testing.T) {
		resp, err := agentClient.ListHardwareCapabilities(ctx, &agentpb.ListHardwareCapabilitiesRequest{})
		if err != nil {
			t.Fatalf("ListHardwareCapabilities: %v", err)
		}
		if len(resp.Capabilities) != 1 {
			t.Fatalf("expected 1 capability, got %d", len(resp.Capabilities))
		}
		if resp.Capabilities[0].Category != "gpu" {
			t.Errorf("category = %q; want gpu", resp.Capabilities[0].Category)
		}
	})

	// Step 4: StreamLogs - subscribe and receive
	t.Run("StreamLogs", func(t *testing.T) {
		streamCtx, cancel := context.WithCancel(ctx)
		defer cancel()

		stream, err := telemetryClient.StreamLogs(streamCtx, &agentpb.StreamLogsRequest{})
		if err != nil {
			t.Fatalf("StreamLogs: %v", err)
		}

		// Give server time to register subscriber.
		time.Sleep(50 * time.Millisecond)

		// Publish a log via OTEL receiver.
		_, err = otelLogsClient.Export(ctx, &otelpb.ExportLogsServiceRequest{})
		if err != nil {
			t.Fatalf("OTEL Export: %v", err)
		}

		// Receive the log on the telemetry stream.
		resp, err := stream.Recv()
		if err != nil {
			t.Fatalf("recv log: %v", err)
		}
		if resp.Logs == nil {
			t.Error("expected non-nil logs")
		}

		// Cancel and confirm stream ends.
		cancel()
	})

	// Step 5: WiFi operations
	t.Run("WiFiOperations", func(t *testing.T) {
		nets, err := agentClient.ListWiFiNetworks(ctx, &agentpb.ListWiFiNetworksRequest{})
		if err != nil {
			t.Fatalf("ListWiFiNetworks: %v", err)
		}
		if len(nets.Networks) != 1 {
			t.Errorf("expected 1 network, got %d", len(nets.Networks))
		}

		status, err := agentClient.GetWiFiStatus(ctx, &agentpb.GetWiFiStatusRequest{})
		if err != nil {
			t.Fatalf("GetWiFiStatus: %v", err)
		}
		if !status.Connected {
			t.Error("expected connected")
		}

		connectResp, err := agentClient.ConnectToWiFi(ctx, &agentpb.ConnectToWiFiRequest{
			Ssid:     "IntegrationNet",
			Password: "pass",
		})
		if err != nil {
			t.Fatalf("ConnectToWiFi: %v", err)
		}
		if !connectResp.Success {
			t.Error("expected success")
		}

		disconnResp, err := agentClient.DisconnectWiFi(ctx, &agentpb.DisconnectWiFiRequest{})
		if err != nil {
			t.Fatalf("DisconnectWiFi: %v", err)
		}
		if !disconnResp.Success {
			t.Error("expected disconnect success")
		}
	})

	fmt.Println("Full agent lifecycle integration test passed")
}
