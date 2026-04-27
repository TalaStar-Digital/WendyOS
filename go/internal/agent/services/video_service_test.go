package services

import (
	"context"
	"fmt"
	"testing"

	"go.uber.org/zap"
	agentpb "github.com/wendylabsinc/wendy/proto/gen/agentpb"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// newTestVideoService creates a VideoService with injectable filesystem functions.
func newTestVideoService(glob func() ([]string, error), readName func(string) (string, error)) *VideoService {
	svc := NewVideoService(zap.NewNop())
	if glob != nil {
		svc.globDevices = glob
	}
	if readName != nil {
		svc.readDeviceName = readName
	}
	return svc
}

func TestListV4L2Devices_TwoDevices(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0", "/dev/video1"}, nil },
		func(base string) (string, error) {
			names := map[string]string{"video0": "USB Camera", "video1": "Integrated Camera"}
			if name, ok := names[base]; ok {
				return name, nil
			}
			return base, nil
		},
	)

	devices, err := svc.listV4L2Devices()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(devices))
	}
	if devices[0].GetId() != 0 || devices[0].GetName() != "USB Camera" || devices[0].GetPath() != "/dev/video0" {
		t.Errorf("device 0: got id=%d name=%q path=%q", devices[0].GetId(), devices[0].GetName(), devices[0].GetPath())
	}
	if devices[1].GetId() != 1 || devices[1].GetName() != "Integrated Camera" || devices[1].GetPath() != "/dev/video1" {
		t.Errorf("device 1: got id=%d name=%q path=%q", devices[1].GetId(), devices[1].GetName(), devices[1].GetPath())
	}
}

func TestListV4L2Devices_NoDevices(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return nil, nil },
		nil,
	)

	devices, err := svc.listV4L2Devices()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devices) != 0 {
		t.Fatalf("expected 0 devices, got %d", len(devices))
	}
}

func TestListV4L2Devices_SysfsReadFailFallsBackToPath(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0"}, nil },
		func(base string) (string, error) { return "", fmt.Errorf("no sysfs") },
	)

	devices, err := svc.listV4L2Devices()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devices) != 1 {
		t.Fatalf("expected 1 device, got %d", len(devices))
	}
	if devices[0].GetName() != "video0" {
		t.Errorf("expected fallback name 'video0', got %q", devices[0].GetName())
	}
}

func TestListV4L2Devices_GlobError(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return nil, fmt.Errorf("permission denied") },
		nil,
	)

	_, err := svc.listV4L2Devices()
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestVideoService_ListVideoDevices(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0"}, nil },
		func(base string) (string, error) { return "Test Camera", nil },
	)

	resp, err := svc.ListVideoDevices(context.Background(), &agentpb.ListVideoDevicesRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(resp.GetDevices()) != 1 {
		t.Fatalf("expected 1 device, got %d", len(resp.GetDevices()))
	}
	d := resp.GetDevices()[0]
	if d.GetId() != 0 || d.GetName() != "Test Camera" || d.GetPath() != "/dev/video0" {
		t.Errorf("unexpected device: id=%d name=%q path=%q", d.GetId(), d.GetName(), d.GetPath())
	}
}

func TestVideoService_ListVideoDevices_GlobError(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return nil, fmt.Errorf("permission denied") },
		nil,
	)

	_, err := svc.ListVideoDevices(context.Background(), &agentpb.ListVideoDevicesRequest{})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("expected gRPC status error, got: %v", err)
	}
	if st.Code() != codes.Internal {
		t.Errorf("expected codes.Internal, got %v", st.Code())
	}
}
