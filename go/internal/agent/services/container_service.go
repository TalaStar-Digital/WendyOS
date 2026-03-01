package services

import (
	"context"
	"encoding/json"
	"io"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/wendylabsinc/wendy/internal/shared/appconfig"
	agentpb "github.com/wendylabsinc/wendy/proto/gen/agentpb"
)

// ContainerService implements agentpb.WendyContainerServiceServer.
type ContainerService struct {
	agentpb.UnimplementedWendyContainerServiceServer
	logger     *zap.Logger
	containerd ContainerdClient
}

// NewContainerService creates a new ContainerService.
func NewContainerService(logger *zap.Logger, client ContainerdClient) *ContainerService {
	return &ContainerService{
		logger:     logger,
		containerd: client,
	}
}

// ListLayers streams the OCI image layers present in containerd.
func (s *ContainerService) ListLayers(_ *agentpb.ListLayersRequest, stream grpc.ServerStreamingServer[agentpb.LayerHeader]) error {
	ctx := stream.Context()
	layers, err := s.containerd.ListLayers(ctx)
	if err != nil {
		return status.Errorf(codes.Internal, "failed to list layers: %v", err)
	}

	for _, layer := range layers {
		if err := stream.Send(layer); err != nil {
			return err
		}
	}
	return nil
}

// WriteLayer receives a streaming layer upload. Data is piped directly from
// the gRPC stream into the containerd content store to avoid buffering the
// entire layer in memory (which could be hundreds of MB).
func (s *ContainerService) WriteLayer(stream grpc.BidiStreamingServer[agentpb.WriteLayerRequest, agentpb.WriteLayerResponse]) error {
	ctx := stream.Context()

	// Receive the first message to get the digest.
	first, err := stream.Recv()
	if err == io.EOF {
		return status.Error(codes.InvalidArgument, "empty layer upload stream")
	}
	if err != nil {
		return status.Errorf(codes.Internal, "error receiving first layer message: %v", err)
	}

	digest := first.GetDigest()
	if digest == "" {
		return status.Error(codes.InvalidArgument, "no digest provided in layer upload")
	}

	// Create an io.Pipe to stream data from the gRPC receiver to the containerd writer.
	pr, pw := io.Pipe()
	var size int64

	// Goroutine to receive chunks and write to the pipe.
	writeErr := make(chan error, 1)
	go func() {
		defer pw.Close()

		// Write the first chunk's data.
		if data := first.GetData(); len(data) > 0 {
			size += int64(len(data))
			if _, err := pw.Write(data); err != nil {
				pw.CloseWithError(err)
				writeErr <- err
				return
			}
		}

		for {
			msg, err := stream.Recv()
			if err == io.EOF {
				writeErr <- nil
				return
			}
			if err != nil {
				pw.CloseWithError(err)
				writeErr <- err
				return
			}
			if data := msg.GetData(); len(data) > 0 {
				size += int64(len(data))
				if _, err := pw.Write(data); err != nil {
					pw.CloseWithError(err)
					writeErr <- err
					return
				}
			}
		}
	}()

	// Pass the pipe reader to containerd client. The size is not known ahead
	// of time in the streaming protocol so we pass 0 and let the content
	// store determine the final size from the reader.
	if err := s.containerd.WriteLayer(ctx, digest, pr, 0); err != nil {
		return status.Errorf(codes.Internal, "failed to write layer: %v", err)
	}

	// Wait for the receiver goroutine to finish.
	if recvErr := <-writeErr; recvErr != nil {
		return status.Errorf(codes.Internal, "error receiving layer data: %v", recvErr)
	}

	s.logger.Info("Layer written", zap.String("digest", digest), zap.Int64("size", size))
	return stream.Send(&agentpb.WriteLayerResponse{})
}

// CreateContainer creates a container from an image with entitlements.
func (s *ContainerService) CreateContainer(ctx context.Context, req *agentpb.CreateContainerRequest) (*agentpb.CreateContainerResponse, error) {
	appCfg, err := parseAppConfig(req.GetAppConfig())
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid app config: %v", err)
	}

	if err := s.containerd.CreateContainer(ctx, req, appCfg); err != nil {
		return nil, status.Errorf(codes.Internal, "failed to create container: %v", err)
	}

	s.logger.Info("Container created",
		zap.String("app_name", req.GetAppName()),
		zap.String("image", req.GetImageName()),
	)
	return &agentpb.CreateContainerResponse{}, nil
}

// CreateContainerWithProgress creates a container and streams progress.
func (s *ContainerService) CreateContainerWithProgress(req *agentpb.CreateContainerRequest, stream grpc.ServerStreamingServer[agentpb.CreateContainerProgressResponse]) error {
	appCfg, err := parseAppConfig(req.GetAppConfig())
	if err != nil {
		return status.Errorf(codes.InvalidArgument, "invalid app config: %v", err)
	}

	if err := s.containerd.CreateContainer(stream.Context(), req, appCfg); err != nil {
		return status.Errorf(codes.Internal, "failed to create container: %v", err)
	}

	// Send completed response.
	return stream.Send(&agentpb.CreateContainerProgressResponse{
		ResponseType: &agentpb.CreateContainerProgressResponse_Completed{
			Completed: &agentpb.CreateContainerResponse{},
		},
	})
}

// RunContainer runs a container and streams stdout/stderr.
func (s *ContainerService) RunContainer(req *agentpb.RunContainerLayersRequest, stream grpc.ServerStreamingServer[agentpb.RunContainerLayersResponse]) error {
	ctx := stream.Context()

	// Parse app config.
	appCfg, err := parseAppConfig(req.GetAppConfig())
	if err != nil {
		return status.Errorf(codes.InvalidArgument, "invalid app config: %v", err)
	}

	// Create the container first.
	createReq := &agentpb.CreateContainerRequest{
		ImageName:     req.GetImageName(),
		AppName:       req.GetAppName(),
		Cmd:           req.GetCmd(),
		AppConfig:     req.GetAppConfig(),
		WorkingDir:    req.GetWorkingDir(),
		RestartPolicy: req.GetRestartPolicy(),
		UserArgs:      req.GetUserArgs(),
	}

	if err := s.containerd.CreateContainer(ctx, createReq, appCfg); err != nil {
		return status.Errorf(codes.Internal, "failed to create container: %v", err)
	}

	return s.streamContainerOutput(ctx, req.GetAppName(), stream)
}

// StartContainer starts an existing container and streams output.
func (s *ContainerService) StartContainer(req *agentpb.StartContainerRequest, stream grpc.ServerStreamingServer[agentpb.RunContainerLayersResponse]) error {
	return s.streamContainerOutput(stream.Context(), req.GetAppName(), stream)
}

// streamContainerOutput starts a container and streams its stdout/stderr to the client.
func (s *ContainerService) streamContainerOutput(
	ctx context.Context,
	appName string,
	stream grpc.ServerStreamingServer[agentpb.RunContainerLayersResponse],
) error {
	outputCh, err := s.containerd.StartContainer(ctx, appName)
	if err != nil {
		return status.Errorf(codes.Internal, "failed to start container: %v", err)
	}

	// Send started notification.
	if err := stream.Send(&agentpb.RunContainerLayersResponse{
		ResponseType: &agentpb.RunContainerLayersResponse_Started_{
			Started: &agentpb.RunContainerLayersResponse_Started{},
		},
	}); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case output, ok := <-outputCh:
			if !ok || output.Done {
				return nil
			}
			if len(output.Stdout) > 0 {
				if err := stream.Send(&agentpb.RunContainerLayersResponse{
					ResponseType: &agentpb.RunContainerLayersResponse_StdoutOutput{
						StdoutOutput: &agentpb.RunContainerLayersResponse_ConsoleOutput{
							Data: output.Stdout,
						},
					},
				}); err != nil {
					return err
				}
			}
			if len(output.Stderr) > 0 {
				if err := stream.Send(&agentpb.RunContainerLayersResponse{
					ResponseType: &agentpb.RunContainerLayersResponse_StderrOutput{
						StderrOutput: &agentpb.RunContainerLayersResponse_ConsoleOutput{
							Data: output.Stderr,
						},
					},
				}); err != nil {
					return err
				}
			}
		}
	}
}

// StopContainer stops a running container.
func (s *ContainerService) StopContainer(ctx context.Context, req *agentpb.StopContainerRequest) (*agentpb.StopContainerResponse, error) {
	if err := s.containerd.StopContainer(ctx, req.GetAppName()); err != nil {
		return nil, status.Errorf(codes.Internal, "failed to stop container: %v", err)
	}
	s.logger.Info("Container stopped", zap.String("app_name", req.GetAppName()))
	return &agentpb.StopContainerResponse{}, nil
}

// DeleteContainer deletes a container and optionally its image.
func (s *ContainerService) DeleteContainer(ctx context.Context, req *agentpb.DeleteContainerRequest) (*agentpb.DeleteContainerResponse, error) {
	if err := s.containerd.DeleteContainer(ctx, req.GetAppName(), req.GetDeleteImage()); err != nil {
		return nil, status.Errorf(codes.Internal, "failed to delete container: %v", err)
	}
	s.logger.Info("Container deleted",
		zap.String("app_name", req.GetAppName()),
		zap.Bool("delete_image", req.GetDeleteImage()),
	)
	return &agentpb.DeleteContainerResponse{}, nil
}

// ListContainers lists running containers.
func (s *ContainerService) ListContainers(_ *agentpb.ListContainersRequest, stream grpc.ServerStreamingServer[agentpb.ListContainersResponse]) error {
	containers, err := s.containerd.ListContainers(stream.Context())
	if err != nil {
		return status.Errorf(codes.Internal, "failed to list containers: %v", err)
	}

	for _, c := range containers {
		if err := stream.Send(&agentpb.ListContainersResponse{Container: c}); err != nil {
			return err
		}
	}
	return nil
}

// parseAppConfig parses the wendy.json app config bytes.
func parseAppConfig(data []byte) (*appconfig.AppConfig, error) {
	if len(data) == 0 {
		return &appconfig.AppConfig{}, nil
	}
	var cfg appconfig.AppConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}
