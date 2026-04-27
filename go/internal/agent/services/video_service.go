package services

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	agentpb "github.com/wendylabsinc/wendy/proto/gen/agentpb"
)

// VideoService implements agentpb.WendyVideoServiceServer.
type VideoService struct {
	agentpb.UnimplementedWendyVideoServiceServer
	logger         *zap.Logger
	globDevices    func() ([]string, error)
	readDeviceName func(base string) (string, error)
}

// NewVideoService creates a new VideoService.
func NewVideoService(logger *zap.Logger) *VideoService {
	return &VideoService{
		logger: logger,
		globDevices: func() ([]string, error) {
			return filepath.Glob("/dev/video*")
		},
		readDeviceName: func(base string) (string, error) {
			b, err := os.ReadFile(fmt.Sprintf("/sys/class/video4linux/%s/name", base))
			return strings.TrimSpace(string(b)), err
		},
	}
}

// listV4L2Devices enumerates /dev/video* and reads human-readable names from sysfs.
func (s *VideoService) listV4L2Devices() ([]*agentpb.VideoDevice, error) {
	paths, err := s.globDevices()
	if err != nil {
		return nil, err
	}
	var devices []*agentpb.VideoDevice
	for _, path := range paths {
		base := filepath.Base(path)
		numStr := strings.TrimPrefix(base, "video")
		id, err := strconv.ParseUint(numStr, 10, 32)
		if err != nil {
			continue
		}
		name, err := s.readDeviceName(base)
		if err != nil {
			name = base
		}
		devices = append(devices, &agentpb.VideoDevice{
			Id:   uint32(id),
			Name: name,
			Path: path,
		})
	}
	return devices, nil
}

// ListVideoDevices enumerates V4L2 video capture devices.
func (s *VideoService) ListVideoDevices(ctx context.Context, _ *agentpb.ListVideoDevicesRequest) (*agentpb.ListVideoDevicesResponse, error) {
	devices, err := s.listV4L2Devices()
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to enumerate video devices: %v", err)
	}
	return &agentpb.ListVideoDevicesResponse{Devices: devices}, nil
}
